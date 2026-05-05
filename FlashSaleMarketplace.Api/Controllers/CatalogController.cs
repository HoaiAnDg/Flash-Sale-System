using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;
using StackExchange.Redis;
using System.Text.Json;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CatalogController : BaseApiController
    {
        private readonly string _connectionString;
        private readonly IDatabase _redisDb; // Khai báo Redis

        public CatalogController(IConfiguration configuration, IConnectionMultiplexer redis)
        {
            _connectionString = configuration.GetConnectionString("SqlServerConnection") ?? "";
            _redisDb = redis.GetDatabase(); // Tiêm Redis vào Controller
        }

        [HttpGet("flash-sale-items")]
        public async Task<IActionResult> GetFlashSaleItems()
        {
            string cacheKey = "catalog:flashsale:top10";

            // Bước 1: Tìm trong Redis trước (Cực nhanh)
            var cachedData = await _redisDb.StringGetAsync(cacheKey);
            if (!cachedData.IsNullOrEmpty)
            {
                // Nếu Cache HIT -> Trả về ngay, SQL Server không cần làm gì cả!
                var result = JsonSerializer.Deserialize<object>(cachedData!);
                return OkResponse(result, "Đã lấy danh sách từ REDIS CACHE siêu tốc!");
            }

            // Bước 2: Nếu Cache MISS (chưa có), mới tốn sức đi hỏi SQL Server
            using var connection = new SqlConnection(_connectionString);
            var sqlQuery = @"
                SELECT TOP 10 
                    fsi.VariantID AS variantId, 
                    p.ProductName AS productName, 
                    pv.VariantName AS variantName, 
                    fsi.FlashSalePrice AS flashSalePrice 
                FROM FlashSaleItems fsi
                INNER JOIN ProductVariants pv ON fsi.VariantID = pv.VariantID
                INNER JOIN Products p ON pv.ProductID = p.ProductID";

            var realData = (await connection.QueryAsync(sqlQuery)).ToList();

            // Bước 3: Lưu kết quả vào Redis Cache để dành cho lần sau (Cache sống 5 phút)
            var serializedData = JsonSerializer.Serialize(realData);
            await _redisDb.StringSetAsync(cacheKey, serializedData, TimeSpan.FromMinutes(5));

            return OkResponse(realData, "Đã lấy danh sách từ SQL và đẩy lên CACHE thành công!");
        }
    }
}