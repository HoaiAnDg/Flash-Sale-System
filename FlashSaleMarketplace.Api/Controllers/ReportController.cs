using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class ReportController : BaseApiController
    {
        private readonly string _sqlConnectionString;

        public ReportController(IConfiguration config)
        {
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
        }

        [HttpGet("top-selling")]
        public async Task<IActionResult> GetTopSelling()
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                
                // Lấy Top 5 sản phẩm có SoldQuantity cao nhất
                var sqlQuery = @"
                    SELECT TOP 5 
                        p.ProductName + ' - ' + pv.VariantName AS productName, 
                        fsi.SoldQuantity AS sold, 
                        fsi.TotalAllocated AS total
                    FROM FlashSaleItems fsi
                    INNER JOIN ProductVariants pv ON fsi.VariantID = pv.VariantID
                    INNER JOIN Products p ON pv.ProductID = p.ProductID
                    ORDER BY fsi.SoldQuantity DESC";

                var data = await connection.QueryAsync(sqlQuery);
                return OkResponse(data, "Lấy dữ liệu Top 5 thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất: " + ex.Message });
            }
        }
    }
}