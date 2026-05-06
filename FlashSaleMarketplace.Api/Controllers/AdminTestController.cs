using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Dapper;

namespace FlashSaleMarketplace.Api.Controllers
{
    [Route("api/admin/test")]
    [ApiController]
    public class AdminTestController : ControllerBase
    {
        private readonly IHttpClientFactory _httpClientFactory;
        private readonly IConfiguration _configuration;
        private static CancellationTokenSource _cts = new CancellationTokenSource();
        
        // Cờ đánh dấu để chỉ in lỗi ra Terminal đúng 1 lần (tránh spam)
        private static int _errorLogged = 0; 

        public AdminTestController(IHttpClientFactory httpClientFactory, IConfiguration configuration)
        {
            _httpClientFactory = httpClientFactory;
            _configuration = configuration;
        }

        [HttpPost("reset")]
        public async Task<IActionResult> ResetDatabase()
        {
            var connectionString = _configuration.GetConnectionString("SqlServerConnection");
            using var connection = new SqlConnection(connectionString);
            
            var sql = @"
                SET NOCOUNT ON;
                DELETE FROM TransactionLogs; DELETE FROM Payments; DELETE FROM OrderDetails; DELETE FROM Orders;
                DELETE FROM Users; DBCC CHECKIDENT ('Users', RESEED, 0);

                WITH KeepCTE AS (SELECT TOP 5 FlashSaleItemID FROM FlashSaleItems ORDER BY FlashSaleItemID)
                DELETE FROM FlashSaleItems WHERE FlashSaleItemID NOT IN (SELECT FlashSaleItemID FROM KeepCTE);

                UPDATE FlashSaleEvents SET StartTime = DATEADD(HOUR, -1, GETDATE()), EndTime = DATEADD(HOUR, 5, GETDATE());
                UPDATE FlashSaleItems SET SoldQuantity = 0, TotalAllocated = 1000;
                UPDATE Inventory SET ReservedQuantity = 0, StockQuantity = 5000 WHERE VariantID IN (SELECT VariantID FROM FlashSaleItems);

                WITH L0 AS (SELECT c FROM (VALUES(1),(1)) AS D(c)), L1 AS (SELECT 1 AS c FROM L0 AS A CROSS JOIN L0 AS B),
                     L2 AS (SELECT 1 AS c FROM L1 AS A CROSS JOIN L1 AS B), L3 AS (SELECT 1 AS c FROM L2 AS A CROSS JOIN L2 AS B),
                     L4 AS (SELECT 1 AS c FROM L3 AS A CROSS JOIN L3 AS B), L5 AS (SELECT 1 AS c FROM L4 AS A CROSS JOIN L4 AS B),
                     Nums AS (SELECT ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS rownum FROM L5)
                INSERT INTO Users (FullName, Email, Phone)
                SELECT TOP (50000) 'Khach Hang ' + CAST(rownum AS VARCHAR(10)), 'kh' + CAST(rownum AS VARCHAR(10)) + '@flashsale.com', '0900000000' FROM Nums;
            ";
            await connection.ExecuteAsync(sql, commandTimeout: 120);

            try 
            {
                var client = _httpClientFactory.CreateClient();
                client.BaseAddress = new Uri($"http://127.0.0.1:{Request.Host.Port}"); 
                await client.PostAsync("/api/checkout/preload-redis", null);
                return Ok(new { message = "Thành công: Đã dọn dẹp SQL, tạo 50.000 User và Nạp Redis!" });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = "Reset SQL OK nhưng lỗi Redis: " + ex.Message });
            }
        }

        [HttpPost("start-load")]
        public async Task<IActionResult> StartLoadTest([FromBody] LoadTestRequest req)
        {
            var connectionString = _configuration.GetConnectionString("SqlServerConnection");
            List<int> hotVariants;

            using (var connection = new SqlConnection(connectionString))
            {
                hotVariants = (await connection.QueryAsync<int>("SELECT VariantID FROM FlashSaleItems")).ToList();
            }

            if (!hotVariants.Any()) return BadRequest(new { message = "Lỗi: Không có sản phẩm Flash Sale nào!" });

            _cts.Cancel();
            _cts = new CancellationTokenSource();
            var token = _cts.Token;
            var baseUrl = $"http://127.0.0.1:{Request.Host.Port}";
            Interlocked.Exchange(ref _errorLogged, 0);

            // =========================================================================
            // TỐI ƯU 1: Bơm Thread (Ép CPU làm việc hết công suất ngay từ giây đầu tiên)
            // JMeter mặc định tạo sẵn hàng ngàn luồng, .NET thì tạo từ từ. Phải ép nó!
            // =========================================================================
            ThreadPool.SetMinThreads(req.ConcurrentThreads, req.ConcurrentThreads);

            _ = Task.Run(async () =>
            {
                // =========================================================================
                // TỐI ƯU 2: Phá vỡ giới hạn Socket (MaxConnectionsPerServer)
                // =========================================================================
                var handler = new SocketsHttpHandler
                {
                    MaxConnectionsPerServer = req.ConcurrentThreads * 2, // Cho phép mở hàng ngàn kết nối TCP cùng lúc
                    PooledConnectionLifetime = TimeSpan.FromMinutes(2)
                };

                // Bỏ qua IHttpClientFactory để xài HttpHandler chuyên dụng cho Load Test
                using var client = new HttpClient(handler) { BaseAddress = new Uri(baseUrl) };

                var requests = Enumerable.Range(1, req.TotalRequests);
                var options = new ParallelOptions 
                { 
                    MaxDegreeOfParallelism = req.ConcurrentThreads, 
                    CancellationToken = token 
                };
                
                try {
                    await Parallel.ForEachAsync(requests, options, async (i, ct) =>
                    {
                        try {
                            int randomUser = Random.Shared.Next(1, 50000);

                            await Task.Delay(Random.Shared.Next(1, 5)); // Giả lập độ trễ mạng Internet từ 1-5ms của user
                            
                            // =========================================================================
                            // TỐI ƯU 3: Bỏ qua Serialization thư viện (Ghép chuỗi tĩnh siêu tốc)
                            // =========================================================================
                            string jsonPayload = $"{{\"UserId\":{randomUser}}}";
                            using var content = new StringContent(jsonPayload, System.Text.Encoding.UTF8, "application/json");

                            // =========================================================================
                            // TỐI ƯU 4: Fire & Forget (Bắn xong chạy ngay, không tải Body phản hồi)
                            // =========================================================================
                            using var response = await client.PostAsync("/api/checkout/stress-test", content, ct);
                            
                            if (!response.IsSuccessStatusCode && Interlocked.Exchange(ref _errorLogged, 1) == 0)
                            {
                                var err = await response.Content.ReadAsStringAsync(ct);
                                Console.WriteLine($"\n[BÁO ĐỘNG] LỖI {response.StatusCode}: {err}\n");
                            }
                        } catch { /* Bỏ qua Timeout để bắn liên tục */ }
                    });
                } catch (OperationCanceledException) { }
            }, token);

            return Ok(new { message = $"Đã mở khóa giới hạn! Đang bắn đạn đạo {req.TotalRequests} requests..." });
        }

        [HttpPost("stop-load")]
        public IActionResult StopLoadTest()
        {
            _cts.Cancel();
            return Ok(new { message = "Đã dừng bắn tải thành công!" });
        }

        [HttpPost("schedule")]
        public async Task<IActionResult> ScheduleFlashSale([FromBody] ScheduleRequest req)
        {
            var connectionString = _configuration.GetConnectionString("SqlServerConnection");
            using var connection = new SqlConnection(connectionString);
            
            // Ép cứng EndTime = StartTime + 5 phút
            var sql = @"
                UPDATE FlashSaleEvents 
                SET StartTime = DATEADD(SECOND, @Delay, GETDATE()), 
                    EndTime = DATEADD(MINUTE, 5, DATEADD(SECOND, @Delay, GETDATE()));
            ";
            
            await connection.ExecuteAsync(sql, new { Delay = req.DelaySeconds });
            
            return Ok(new { message = $"Đã lên lịch! Flash Sale sẽ bùng nổ sau {req.DelaySeconds} giây và kéo dài 5 phút." });
        }
    }

    public class ScheduleRequest
    {
        public int DelaySeconds { get; set; } = 10;
        public int DurationMinutes { get; set; } = 60;
    }

    public class LoadTestRequest
    {
        public int TotalRequests { get; set; } = 150000;
        public int ConcurrentThreads { get; set; } = 500;
    }
}