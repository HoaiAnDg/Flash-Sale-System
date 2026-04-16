using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CatalogController : BaseApiController
    {
        private readonly string _connectionString;

        // Dependency Injection: Lấy chuỗi kết nối từ appsettings.json
        public CatalogController(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("SqlServerConnection") ?? "";
        }

        [HttpGet("flash-sale-items")]
        public async Task<IActionResult> GetFlashSaleItems()
        {
            // Mở đường ống kết nối đến SQL Server
            using var connection = new SqlConnection(_connectionString);

            // Viết câu lệnh JOIN 3 bảng để lấy đúng dữ liệu UI cần
            // (Chỉ lấy TOP 10 sản phẩm để web không bị lag vì DB đang có tới 50.000 sản phẩm Flash Sale)
            var sqlQuery = @"
                SELECT TOP 10 
                    fsi.VariantID AS variantId, 
                    p.ProductName AS productName, 
                    pv.VariantName AS variantName, 
                    fsi.FlashSalePrice AS flashSalePrice 
                FROM FlashSaleItems fsi
                INNER JOIN ProductVariants pv ON fsi.VariantID = pv.VariantID
                INNER JOIN Products p ON pv.ProductID = p.ProductID";

            // Dapper tự động thực thi và map dữ liệu
            var realData = await connection.QueryAsync(sqlQuery);

            return OkResponse(realData, "Đã lấy danh sách từ SQL Server THẬT thành công!");
        }
    }
}