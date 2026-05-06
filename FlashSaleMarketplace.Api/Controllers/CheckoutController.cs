using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.Models;
using MongoDB.Driver;
using Dapper;
using Microsoft.Data.SqlClient;
using System.Data;
using StackExchange.Redis;
using FlashSaleMarketplace.Api.Messaging;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CheckoutController : BaseApiController
    {
        private readonly IMongoCollection<Cart> _cartCollection;
        private readonly string _sqlConnectionString;
        private readonly IDatabase _redisDb; 
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

        public class FlashSaleInfo
        {
            public int EventID { get; set; }
            public DateTime EndTime { get; set; }
        }

        // =========================================================================
        // API MỚI: Dọn cỗ lên RAM (Chạy 1 lần trước khi diễn ra Flash Sale)
        // =========================================================================
        [HttpPost("preload-redis")]
        public async Task<IActionResult> PreloadRedis()
        {
            await _redisDb.KeyDeleteAsync("fs:active_variants"); 

            using var connection = new SqlConnection(_sqlConnectionString);
            
            // Tìm 5 món đang được Sale — chỉ định rõ tên bảng để tránh ambiguous column
            var items = await connection.QueryAsync<dynamic>("SELECT fsi.EventID, fsi.VariantID, fsi.TotalAllocated, fse.StartTime, fse.EndTime FROM FlashSaleItems fsi INNER JOIN FlashSaleEvents fse ON fsi.EventID = fse.EventID");

            foreach (var item in items)
            {
                await _redisDb.StringSetAsync($"fs:stock:variant:{item.VariantID}", (int)item.TotalAllocated);
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

                int eventId = (int)await _redisDb.StringGetAsync($"fs:event:variant:{variantId}");
                
                // [FIX]: Tự động sinh Guid mới cho mỗi Request bắn tải để không bị trùng khóa chính (00000...0000)
                var newOrderId = Guid.NewGuid();
                var orderMessage = new { OrderId = newOrderId, UserId = request.UserId, VariantId = variantId, EventId = eventId };

                _producer.PublishMessage("order_queue", orderMessage);

                return Ok(new { message = $"RAM chốt siêu tốc! Đơn hàng đang được hệ thống xử lý nền." });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = "Lỗi hệ thống: " + ex.Message });
            }
        }

        // =========================================================================
        // CHỐT ĐƠN & PHÂN LOẠI (FLASH SALE vs HÀNG THƯỜNG)
        // =========================================================================
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
                var itemsToKeep = new List<CartItem>(); // Danh sách các món phải giữ lại trong giỏ

                foreach (var item in cart.Items)
                {
                    if (item.IsFlashSale) 
                    {
                        var fsInfo = await connection.QueryFirstOrDefaultAsync<FlashSaleInfo>(@"
                            SELECT fsi.EventID, fse.EndTime 
                            FROM FlashSaleItems fsi 
                            INNER JOIN FlashSaleEvents fse ON fse.EventID = fse.EventID 
                            WHERE fsi.VariantID = @vid", new { vid = item.VariantId });

                        bool isFlashSaleActive = fsInfo != null && fsInfo.EndTime >= DateTime.Now;

                        if (isFlashSaleActive)
                        {
                            int eventId = fsInfo!.EventID; 
                            string stockKey = $"fs:stock:variant:{item.VariantId}";
                            string userKey = $"fs:userbought:{item.VariantId}:{request.UserId}"; 

                            string luaScript = @"
                                if redis.call('EXISTS', KEYS[2]) == 1 then return -1 end
                                local stock = tonumber(redis.call('GET', KEYS[1]))
                                if stock == nil or stock <= 0 then return -2 end
                                redis.call('DECR', KEYS[1])      
                                redis.call('SET', KEYS[2], '1')  
                                return 1
                            ";
                            
                            var luaResult = (int)await _redisDb.ScriptEvaluateAsync(luaScript, new RedisKey[] { stockKey, userKey });
                            
                            // [FIX Ở ĐÂY]: Gộp chung lỗi -1 (Đã mua) và -2 (Hết suất)
                            if (luaResult == -1 || luaResult == -2) 
                            {
                                // Lập tức tước quyền Flash Sale, lấy lại giá gốc
                                var originalPrice = await connection.QueryFirstOrDefaultAsync<decimal>(
                                    "SELECT Price FROM ProductVariants WHERE VariantID = @vid", new { vid = item.VariantId });
                                
                                item.Price = originalPrice;
                                item.IsFlashSale = false; // Biến thành hàng thường
                                itemsToKeep.Add(item);    // Giữ lại trong giỏ hàng để user quyết định
                                
                                string reason = luaResult == -1 ? "Bạn đã hết lượt mua Flash Sale" : "Đã hết suất Flash Sale";
                                results.Add($"⚠️ {item.ProductName}: {reason}! Đã tự động chuyển về hàng thường (Giá gốc).");
                            } 
                            else 
                            {
                                var flashSaleOrderId = Guid.NewGuid();
                                _producer.PublishMessage("order_queue", new { OrderId = flashSaleOrderId, UserId = request.UserId, VariantId = item.VariantId, EventId = eventId });
                                results.Add($"⚡ {item.ProductName}: Thành công. Mã đơn: {flashSaleOrderId}");
                            }
                        }
                        else
                        {
                            // Flash sale kết thúc -> Lùi giá và GIỮ LẠI giỏ hàng
                            var originalPrice = await connection.QueryFirstOrDefaultAsync<decimal>(
                                "SELECT Price FROM ProductVariants WHERE VariantID = @vid", new { vid = item.VariantId });
                            item.Price = originalPrice;
                            item.IsFlashSale = false;
                            itemsToKeep.Add(item);
                            results.Add($"⚠️ {item.ProductName}: Flash Sale đã kết thúc! Tự động lùi về giá gốc.");
                        }
                    }
                    else
                    {
                        var sqlNormal = @"
                            SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
                            BEGIN TRAN;
                            BEGIN TRY
                                DECLARE @ActualPrice DECIMAL(18,2);
                                SELECT @ActualPrice = Price FROM ProductVariants WHERE VariantID = @VariantId;

                                INSERT INTO Orders (OrderID, CustomerID, TotalAmount, Status, OrderDate) 
                                VALUES (@NewOrderID, @UserId, @ActualPrice * @Qty, 1, GETDATE());

                                INSERT INTO OrderDetails (OrderID, VariantID, Quantity, UnitPrice) 
                                VALUES (@NewOrderID, @VariantId, @Qty, @ActualPrice);

                                UPDATE Inventory SET StockQuantity = StockQuantity - @Qty WHERE VariantID = @VariantId;

                                COMMIT TRAN;
                            END TRY
                            BEGIN CATCH
                                ROLLBACK TRAN;
                                THROW;
                            END CATCH
                        ";
                        
                        try {
                            var newOrderId = Guid.NewGuid(); 
                            await connection.ExecuteAsync(sqlNormal, new { NewOrderID = newOrderId, UserId = request.UserId, VariantId = item.VariantId, Qty = item.Quantity > 0 ? item.Quantity : 1 });
                            results.Add($"🛒 {item.ProductName}: Thành công. Mã đơn: {newOrderId}"); 
                        }
                        catch (Exception ex) {
                            results.Add($"🛒 {item.ProductName}: Thất bại (Lỗi: {ex.Message})");
                            itemsToKeep.Add(item); // Giữ lại trong giỏ nếu mua lỗi
                        }
                    }
                }

                // Cập nhật lại giỏ hàng MongoDB với các trạng thái IsFlashSale = false mới nhất
                if (itemsToKeep.Any())
                {
                    var update = Builders<Cart>.Update.Set(c => c.Items, itemsToKeep);
                    await _cartCollection.UpdateOneAsync(c => c.Id == cart.Id, update);
                }
                else
                {
                    var update = Builders<Cart>.Update.Set(c => c.Status, "completed");
                    await _cartCollection.UpdateOneAsync(c => c.Id == cart.Id, update);
                }

                return OkResponse(results, "Đã hoàn tất kiểm tra giỏ hàng đa luồng!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi Server: " + ex.Message });
            }
        }

        [HttpGet("history/{userId}")]
        public async Task<IActionResult> GetOrderHistory(int userId)
        {
            using var connection = new SqlConnection(_sqlConnectionString);
            var sql = @"
                SELECT OrderID, TotalAmount, OrderDate, Status 
                FROM Orders 
                WHERE CustomerID = @uid 
                ORDER BY OrderDate DESC";
            
            var orders = await connection.QueryAsync(sql, new { uid = userId });
            return OkResponse(orders, "Tải lịch sử đơn hàng thành công!");
        }

        public class ConfirmRequest
        {
            public Guid OrderId { get; set; }
            public string Method { get; set; } = string.Empty;
        }

        [HttpPost("confirm-payment")]
        public async Task<IActionResult> ConfirmPayment([FromBody] ConfirmRequest req)
        {
            Console.WriteLine($"\n[PAYMENT] Nhận yêu cầu xác nhận đơn: {req.OrderId}");
            try 
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                for (int i = 0; i < 3; i++) 
                {
                    var parameters = new DynamicParameters();
                    parameters.Add("@OrderID", req.OrderId);
                    parameters.Add("@PaymentMethod", req.Method);
                    parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
                    parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

                    await connection.ExecuteAsync("sp_ConfirmPayment", parameters, commandType: CommandType.StoredProcedure);

                    int resultCode = parameters.Get<int>("@ResultCode");
                    string resultMsg = parameters.Get<string>("@ResultMsg");

                    Console.WriteLine($"  -> Lần thử {i+1}: ResultCode={resultCode}, Msg={resultMsg}");

                    if (resultCode == 0 || resultMsg.Contains("Trạng thái hiện tại: 1")) 
                        return Ok(new { success = true, message = resultMsg });

                    if (resultCode == -1) { 
                        Console.WriteLine("  -> [!] Chưa tìm thấy đơn trong SQL, đang đợi Worker...");
                        await Task.Delay(1500); 
                        continue; 
                    }

                    return Ok(new { success = false, message = resultMsg });
                }
                return Ok(new { success = false, message = "Hệ thống bận." });
            }
            catch (Exception ex) { 
                Console.WriteLine($"[ERROR] {ex.Message}");
                return StatusCode(500, new { success = false, message = ex.Message }); 
            }
        }

        public class CancelRequest
        {
            public Guid OrderId { get; set; }
            public int UserId { get; set; }
        }

        [HttpPost("cancel")]
        public async Task<IActionResult> CancelOrder([FromBody] CancelRequest req)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                await connection.OpenAsync();

                using var transaction = connection.BeginTransaction();

                try
                {
                    var verifyOrder = await connection.QueryFirstOrDefaultAsync<dynamic>(
                        @"SELECT OrderID, CustomerID, Status FROM Orders 
                          WHERE OrderID = @OrderID AND CustomerID = @CustomerID AND Status = 1",
                        new { OrderID = req.OrderId, CustomerID = req.UserId },
                        transaction: transaction
                    );

                    if (verifyOrder == null)
                    {
                        await transaction.RollbackAsync();
                        return Ok(new { success = false, message = "Đơn hàng không tồn tại hoặc không thể hủy (chỉ có thể hủy đơn thành công)." });
                    }

                    var orderItems = await connection.QueryAsync<dynamic>(
                        @"SELECT VariantID, Quantity FROM OrderDetails WHERE OrderID = @OrderID",
                        new { OrderID = req.OrderId },
                        transaction: transaction
                    );

                    var itemsList = orderItems.ToList();

                    foreach (var item in itemsList)
                    {
                        int variantId = (int)item.VariantID;
                        int quantity = (int)item.Quantity;

                        await connection.ExecuteAsync(
                            @"UPDATE Inventory 
                              SET StockQuantity = StockQuantity + @Qty
                              WHERE VariantID = @VariantID",
                            new { VariantID = variantId, Qty = quantity },
                            transaction: transaction
                        );

                            var rowsAffected = await connection.ExecuteAsync(
                                @"UPDATE FlashSaleItems 
                                  SET SoldQuantity = SoldQuantity - @Qty 
                                  WHERE VariantID = @VariantID AND SoldQuantity >= @Qty",
                                new { VariantID = variantId, Qty = quantity },
                                transaction: transaction
                            );

                            if (rowsAffected > 0)
                            {
                                try
                                {
                                    await _redisDb.StringIncrementAsync($"fs:stock:variant:{variantId}", quantity);
                                }
                                catch
                                {
                                    Console.WriteLine($"[WARN] Không thể cập nhật Redis fs:stock:variant:{variantId} khi hủy đơn {req.OrderId}");
                                }
                            }
                    }

                    await connection.ExecuteAsync(
                        @"UPDATE Orders 
                          SET Status = 2, OrderDate = GETDATE()
                          WHERE OrderID = @OrderID",
                        new { OrderID = req.OrderId },
                        transaction: transaction
                    );

                    await transaction.CommitAsync();

                    return OkResponse(null, $"Đơn hàng {req.OrderId} đã được hủy thành công. Kho hàng đã được hoàn lại.");
                }
                catch (Exception innerEx)
                {
                    await transaction.RollbackAsync();
                    return StatusCode(500, new { success = false, message = $"Lỗi trong quá trình xử lý hủy đơn: {innerEx.Message}" });
                }
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi hệ thống hủy đơn: " + ex.Message });
            }
        }

        [HttpGet("details/{orderId}")]
        public async Task<IActionResult> GetOrderDetails(Guid orderId)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                
                var orderDetails = await connection.QueryAsync<dynamic>(
                    @"SELECT 
                        od.VariantID as variantId,
                        p.ProductName as productName,
                        pv.VariantName as variantName,
                        pv.Price as originalPrice,
                        od.Quantity as quantity
                      FROM OrderDetails od
                      INNER JOIN ProductVariants pv ON od.VariantID = pv.VariantID
                      INNER JOIN Products p ON pv.ProductID = p.ProductID
                      WHERE od.OrderID = @OrderID",
                    new { OrderID = orderId }
                );

                return OkResponse(orderDetails, "Lấy chi tiết đơn hàng thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi lấy chi tiết đơn: " + ex.Message });
            }
        }
    }
}