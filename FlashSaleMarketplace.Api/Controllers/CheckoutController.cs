using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.Models;
using MongoDB.Driver;
using Dapper;
using Microsoft.Data.SqlClient;
using System.Data;
using StackExchange.Redis;
using FlashSaleMarketplace.Api.Messaging;
using Microsoft.AspNetCore.RateLimiting;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CheckoutController : BaseApiController
    {
        private readonly IMongoCollection<Cart> _cartCollection;
        private readonly string _sqlConnectionString;
        private readonly IDatabase _redisDb; // Thêm Redis
        private readonly RabbitMqProducer _producer;

        public CheckoutController(IMongoDatabase mongoDatabase, IConfiguration config, IConnectionMultiplexer redis, RabbitMqProducer producer)
        {
            _cartCollection = mongoDatabase.GetCollection<Cart>("Carts");
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
            _redisDb = redis.GetDatabase();
            _producer = producer;
        }

        public class CheckoutRequest
        {
            public int UserId { get; set; }
        }

        public class CancelOrderRequest
        {
            public Guid OrderId { get; set; }
            public int UserId { get; set; }
        }

        // =========================================================================
        // API MỚI: Dọn cỗ lên RAM (Chạy 1 lần trước khi diễn ra Flash Sale)
        // =========================================================================
        [HttpPost("preload-redis")]
        public async Task<IActionResult> PreloadRedis()
        {
            // [THÊM DÒNG NÀY] Xóa danh sách sản phẩm rác cũ trên RAM
            await _redisDb.KeyDeleteAsync("fs:active_variants"); 

            using var connection = new SqlConnection(_sqlConnectionString);
            
            // Tìm 5 món đang được Sale — chỉ định rõ tên bảng để tránh ambiguous column
            var items = await connection.QueryAsync<dynamic>("SELECT fsi.EventID, fsi.VariantID, fsi.TotalAllocated, fse.StartTime, fse.EndTime FROM FlashSaleItems fsi INNER JOIN FlashSaleEvents fse ON fsi.EventID = fse.EventID");

            foreach (var item in items)
            {
                // Bơm số lượng (TotalAllocated) lên RAM Redis
                await _redisDb.StringSetAsync($"fs:stock:variant:{item.VariantID}", (int)item.TotalAllocated);
                
                // Lưu VariantID vào một tập hợp (Set)
                await _redisDb.SetAddAsync("fs:active_variants", (int)item.VariantID);
                
                await _redisDb.StringSetAsync($"fs:event:variant:{item.VariantID}", (int)item.EventID);

                // FIX 6: Thêm key fs:event:active:{variantId} để kiểm tra event còn hoạt động
                // Key này tự hết hạn khi event kết thúc
                DateTime endTime = item.EndTime;
                TimeSpan expiry = endTime > DateTime.UtcNow ? endTime - DateTime.UtcNow : TimeSpan.Zero;
                
                if (expiry > TimeSpan.Zero)
                {
                    await _redisDb.StringSetAsync($"fs:event:active:{item.VariantID}", "1", expiry);
                }
            }

            return Ok(new { message = "Khởi tạo Kho hàng trên Redis (RAM) thành công!" });
        }


        // =========================================================================
        // API KIẾN TRÚC ENTERPRISE: REDIS LUA + RABBITMQ (Xử lý Bất đồng bộ)
        // =========================================================================
        [EnableRateLimiting("FlashSaleLimit")]
        [HttpPost("stress-test")]
        public async Task<IActionResult> StressTest([FromBody] CheckoutRequest request)
        {
            try
            {
                var randomVariantIdObj = await _redisDb.SetRandomMemberAsync("fs:active_variants");
                if (!randomVariantIdObj.HasValue) 
                    return StatusCode(400, new { message = "Kho RAM trống. Hãy gọi /api/checkout/preload-redis trước!" });

                int variantId = (int)randomVariantIdObj;
                string stockKey = $"fs:stock:variant:{variantId}";
                string userKey = $"fs:userbought:{variantId}:{request.UserId}"; 

            // FIX 6: Lua Script kiểm tra event còn active trước khi cho phép mua
            string luaScript = @"
                -- Check 1: Event còn active không? (key tự hết hạn khi event kết thúc)
                if redis.call('EXISTS', KEYS[3]) == 0 then
                    return -3 -- Event chưa bắt đầu hoặc đã kết thúc
                end
                
                -- Check 2: User đã mua rồi?
                if redis.call('EXISTS', KEYS[2]) == 1 then
                    return -1 -- User đã mua rồi
                end
                
                -- Check 3: Còn kho không?
                local stock = tonumber(redis.call('GET', KEYS[1]))
                if stock == nil or stock <= 0 then
                    return -2 -- Đã hết kho
                end
                
                -- Atomic operation: Giảm kho + Mark user đã mua
                redis.call('DECR', KEYS[1])      
                redis.call('SET', KEYS[2], '1')  
                return 1 -- Thành công
            ";

            var luaResult = (int)await _redisDb.ScriptEvaluateAsync(luaScript, 
                new RedisKey[] { stockKey, userKey, $"fs:event:active:{variantId}" });

                if (luaResult == -1) return StatusCode(400, new { message = "Bạn đã mua sản phẩm này rồi!" });
                if (luaResult == -2) return StatusCode(400, new { message = "Rất tiếc! Đã hết suất Flash Sale." });
                if (luaResult == -3) return StatusCode(400, new { message = "Sự kiện Flash Sale chưa bắt đầu hoặc đã kết thúc." });

                // ============================================================================
                // CHỐT ĐƠN ASYNC: Ném vào Hàng đợi (RabbitMQ) thay vì gọi thẳng SQL
                // ============================================================================
                int eventId = (int)await _redisDb.StringGetAsync($"fs:event:variant:{variantId}");
                
                var orderMessage = new { 
                    UserId = request.UserId, 
                    VariantId = variantId, 
                    EventId = eventId 
                };

                _producer.PublishMessage("order_queue", orderMessage);

                // Trả về ngay lập tức cho Frontend, không cần chờ SQL Server phản hồi!
                return Ok(new { message = $"RAM chốt siêu tốc! Đơn hàng đang được hệ thống xử lý nền." });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = "Lỗi hệ thống: " + ex.Message });
            }
        }

        // =========================================================================
        // API HỦY ĐƠN: Hoàn kho vào Redis + SQL Server (FIX 1)
        // =========================================================================
        [HttpPost("cancel-order")]
        public async Task<IActionResult> CancelOrder([FromBody] CancelOrderRequest request)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                await connection.OpenAsync();

                var parameters = new DynamicParameters();
                parameters.Add("@OrderID", request.OrderId);
                parameters.Add("@CustomerID", request.UserId);
                parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
                parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

                // Gọi SP hủy đơn
                await connection.ExecuteAsync("sp_UserCancel", parameters, commandType: CommandType.StoredProcedure);

                int resultCode = parameters.Get<int>("@ResultCode");
                string resultMsg = parameters.Get<string>("@ResultMsg");

                if (resultCode == 0) 
                {
                    // ✅ Hủy thành công → Hoàn kho vào Redis
                    // Lấy VariantID từ OrderDetails
                    var variantId = await connection.QueryFirstOrDefaultAsync<int>(
                        "SELECT TOP 1 VariantID FROM OrderDetails WHERE OrderID = @oid",
                        new { oid = request.OrderId });

                    if (variantId > 0)
                    {
                        var stockKey = $"fs:stock:variant:{variantId}";
                        // Cộng lại 1 suất vào Redis
                        await _redisDb.StringIncrementAsync(stockKey);
                        
                        Console.ForegroundColor = ConsoleColor.Green;
                        Console.WriteLine($"[REDIS RESTORE] Đã cộng lại 1 suất cho Variant {variantId}");
                        Console.ResetColor();
                    }

                    return OkResponse(null, resultMsg);
                }
                
                return StatusCode(400, new { success = false, message = resultMsg });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi hệ thống: " + ex.Message });
            }
        }

        [HttpPost("process")]
        public async Task<IActionResult> ProcessCheckout([FromBody] CheckoutRequest request)
        {
            try
            {
                var cart = await _cartCollection
                    .Find(c => c.UserId == request.UserId && c.Status == "active")
                    .FirstOrDefaultAsync();

                if (cart == null || !cart.Items.Any()) 
                    return OkResponse(null, "Giỏ hàng của bạn đang trống!");

                using var connection = new SqlConnection(_sqlConnectionString);
                await connection.OpenAsync();

                var results = new List<string>();

                foreach (var item in cart.Items)
                {
                    var eventId = await connection.QueryFirstOrDefaultAsync<int?>(
                        "SELECT TOP 1 EventID FROM FlashSaleItems WHERE VariantID = @vid", 
                        new { vid = item.VariantId });

                    if (eventId == null)
                    {
                        results.Add($"{item.ProductName}: Không có sự kiện Flash Sale hợp lệ.");
                        continue;
                    }

                    var parameters = new DynamicParameters();
                    parameters.Add("@CustomerID", request.UserId);
                    parameters.Add("@VariantID", item.VariantId);
                    parameters.Add("@EventID", eventId);
                    parameters.Add("@OrderID", dbType: DbType.Guid, direction: ParameterDirection.Output);
                    parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
                    parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

                    int maxRetries = 3;
                    for (int i = 0; i < maxRetries; i++)
                    {
                        try
                        {
                            await connection.ExecuteAsync("sp_CheckoutFlashSale", parameters, commandType: CommandType.StoredProcedure);
                            break; // Nếu thành công thì thoát vòng lặp Retry
                        }
                        catch (SqlException ex)
                        {
                            if (ex.Number == 1205 && i < maxRetries - 1) // 1205 là mã lỗi Deadlock
                            {
                                await Task.Delay(100); // Kẹt xe thì đợi 100ms rồi thử đâm đầu vào lại
                                continue;
                            }
                            throw; // Lỗi khác thì quăng ra ngoài
                        }
                    }

                    string resultMsg = parameters.Get<string>("@ResultMsg");
                    results.Add($"{item.ProductName}: {resultMsg}");
                }

                // Chốt xong thì dọn giỏ hàng
                var update = Builders<Cart>.Update.Set(c => c.Status, "completed");
                await _cartCollection.UpdateOneAsync(c => c.Id == cart.Id, update);

                return OkResponse(results, "Đã xử lý giỏ hàng!");
            }
            catch (Exception ex)
            {
                // Ép Backend trả về file JSON chuẩn xác khi bị lỗi, không trả về text thô nữa
                return StatusCode(500, new { success = false, message = "Lỗi SQL Server: " + ex.Message });
            }
        }
    }
}