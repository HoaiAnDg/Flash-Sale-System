using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;
using StackExchange.Redis;
using System.Text.Json;
using System;
using System.Linq;
using System.Threading.Tasks;

namespace FlashSaleMarketplace.Api.Controllers
{
    // 1. TẠO CLASS DTO ĐỂ ÉP KIỂU DỮ LIỆU, TRÁNH LỖI DBNULL CHẾT NGƯỜI
    // 1. TẠO CLASS DTO ĐỂ ÉP KIỂU DỮ LIỆU, TRÁNH LỖI DBNULL CHẾT NGƯỜI
    public class CatalogItemDto
    {
        public int variantId { get; set; }
        
        // Gán = string.Empty để triệt tiêu cảnh báo CS8618
        public string productName { get; set; } = string.Empty; 
        public string variantName { get; set; } = string.Empty; 

        // [ĐÃ SỬA LỖI] Gán string.Empty giống hệt 2 biến bên trên
        public string CategoryName { get; set; } = string.Empty;
        
        public decimal originalPrice { get; set; }
        public decimal? flashSalePrice { get; set; }
        public DateTime? startTime { get; set; }
        public DateTime? endTime { get; set; }
        public int? soldQuantity { get; set; }
        public int? totalAllocated { get; set; }
    }

    public class CatalogController : BaseApiController
    {
        private readonly string _connectionString;
        private readonly IDatabase _redisDb; 

        public CatalogController(IConfiguration configuration, IConnectionMultiplexer redis)
        {
            _connectionString = configuration.GetConnectionString("SqlServerConnection") ?? "";
            _redisDb = redis.GetDatabase(); 
        }

        [HttpGet("flash-sale-items")]
        public async Task<IActionResult> GetFlashSaleItems()
        {
            try 
            {
                // Đổi key lên v7 để xóa ngay bộ nhớ đệm cũ, cập nhật danh sách mới
                string cacheKey = "catalog:all_items_v8";

                var cachedData = await _redisDb.StringGetAsync(cacheKey);
                if (!cachedData.IsNullOrEmpty) 
                { 
                    var data = JsonSerializer.Deserialize<List<CatalogItemDto>>(cachedData!);
                    return OkResponse(data, "Lấy dữ liệu từ Redis siêu tốc!"); 
                }

                using var connection = new SqlConnection(_connectionString);
                
                // THÊM LỆNH ORDER BY ĐỂ ƯU TIÊN SẢN PHẨM FLASH SALE LÊN ĐẦU
                var sqlQuery = @"
                SELECT TOP 60 
                    pv.VariantID AS variantId, 
                    p.ProductName AS productName, 
                    pv.VariantName AS variantName, 
                    c.CategoryName AS categoryName, /* THÊM DÒNG NÀY ĐỂ LẤY DANH MỤC */
                    pv.Price AS originalPrice,
                    fsi.FlashSalePrice AS flashSalePrice,
                    fse.StartTime AS startTime,
                    fse.EndTime AS endTime,
                    fsi.SoldQuantity AS soldQuantity,
                    fsi.TotalAllocated AS totalAllocated
                FROM ProductVariants pv
                INNER JOIN Products p ON pv.ProductID = p.ProductID
                INNER JOIN Categories c ON p.CategoryID = c.CategoryID /* KẾT NỐI BẢNG CATEGORIES */
                LEFT JOIN FlashSaleItems fsi ON fsi.VariantID = pv.VariantID
                LEFT JOIN FlashSaleEvents fse ON fsi.EventID = fse.EventID
                ORDER BY 
                    CASE WHEN fsi.FlashSalePrice IS NOT NULL THEN 1 ELSE 0 END DESC,
                    p.ProductID ASC";

                var realData = (await connection.QueryAsync<CatalogItemDto>(sqlQuery)).ToList();

                var serializedData = JsonSerializer.Serialize(realData);
                await _redisDb.StringSetAsync(cacheKey, serializedData, TimeSpan.FromSeconds(3));

                return OkResponse(realData, "Đã lấy danh mục sản phẩm từ SQL!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi Backend: " + ex.Message });
            }
        }
    }
}