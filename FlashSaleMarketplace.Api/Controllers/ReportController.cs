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

        // =========================================================================
        // FIX 7: Báo cáo tổng kết event — Window Functions + Analytics
        // =========================================================================
        [HttpGet("event-summary/{eventId}")]
        public async Task<IActionResult> GetEventSummary(int eventId)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);

                // Query phân tích event hoàn chỉnh sử dụng GROUP BY + CASE WHEN
                var sqlQuery = @"
                    SELECT
                        e.Title                                     AS EventTitle,
                        e.StartTime,
                        e.EndTime,
                        COUNT(DISTINCT o.OrderID)                  AS TongDonHang,
                        SUM(CASE WHEN o.Status=1 THEN 1 END)       AS DonThanhCong,
                        SUM(CASE WHEN o.Status=2 THEN 1 END)       AS DonHuy,
                        SUM(CASE WHEN o.Status=0 THEN 1 END)       AS DonConPending,
                        SUM(CASE WHEN o.Status=1 THEN o.TotalAmount END) AS DoanhThuThucTe,
                        ISNULL(SUM(CASE WHEN o.Status=1 THEN o.TotalAmount END), 0) AS DoanhThuTotal,
                        -- Tỉ lệ chuyển đổi (%)
                        CASE 
                            WHEN COUNT(DISTINCT o.OrderID) = 0 THEN 0
                            ELSE ROUND(100.0 * SUM(CASE WHEN o.Status=1 THEN 1 END) / COUNT(DISTINCT o.OrderID), 2)
                        END AS TiLeChuyenDoi_Pct,
                        -- Tổng suất đã phân bổ vs đã bán thực tế
                        SUM(fsi.TotalAllocated)                     AS TongSuatPhanBo,
                        SUM(fsi.SoldQuantity)                       AS TongSuatDaBan,
                        -- Hiệu suất lấp đầy (%)
                        CASE
                            WHEN SUM(fsi.TotalAllocated) = 0 THEN 0
                            ELSE ROUND(100.0 * SUM(fsi.SoldQuantity) / SUM(fsi.TotalAllocated), 2)
                        END AS HieuSuatLapDay_Pct
                    FROM FlashSaleEvents e
                    LEFT JOIN FlashSaleItems fsi ON e.EventID = fsi.EventID
                    LEFT JOIN OrderDetails od ON fsi.VariantID = od.VariantID
                    LEFT JOIN Orders o ON od.OrderID = o.OrderID
                    WHERE e.EventID = @EventID
                    GROUP BY e.EventID, e.Title, e.StartTime, e.EndTime";

                var param = new { EventID = eventId };
                var result = await connection.QueryFirstOrDefaultAsync(sqlQuery, param);

                if (result == null)
                    return StatusCode(404, new { success = false, message = "Không tìm thấy event này" });

                return OkResponse(result, "Báo cáo tổng kết event lấy thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất: " + ex.Message });
            }
        }

        // =========================================================================
        // BONUS: Chi tiết từng sản phẩm trong event (Breakdown by variant)
        // =========================================================================
        [HttpGet("event-products/{eventId}")]
        public async Task<IActionResult> GetEventProductBreakdown(int eventId)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);

                var sqlQuery = @"
                    SELECT
                        fsi.VariantID,
                        p.ProductName,
                        pv.VariantName,
                        fsi.FlashSalePrice,
                        fsi.TotalAllocated,
                        fsi.SoldQuantity,
                        (fsi.TotalAllocated - fsi.SoldQuantity) AS ConLai,
                        ROUND(100.0 * fsi.SoldQuantity / fsi.TotalAllocated, 2) AS LapDay_Pct,
                        COUNT(DISTINCT CASE WHEN o.Status=1 THEN o.OrderID END) AS DonThanhCong,
                        COUNT(DISTINCT CASE WHEN o.Status=2 THEN o.OrderID END) AS DonHuy,
                        COUNT(DISTINCT CASE WHEN o.Status=1 THEN o.CustomerID END) AS UniqueCustomer,
                        SUM(CASE WHEN o.Status=1 THEN o.TotalAmount END) AS DoanhThuVariant
                    FROM FlashSaleItems fsi
                    INNER JOIN ProductVariants pv ON fsi.VariantID = pv.VariantID
                    INNER JOIN Products p ON pv.ProductID = p.ProductID
                    LEFT JOIN OrderDetails od ON fsi.VariantID = od.VariantID
                    LEFT JOIN Orders o ON od.OrderID = o.OrderID
                    WHERE fsi.EventID = @EventID
                    GROUP BY 
                        fsi.VariantID, p.ProductName, pv.VariantName, 
                        fsi.FlashSalePrice, fsi.TotalAllocated, fsi.SoldQuantity
                    ORDER BY DoanhThuVariant DESC";

                var param = new { EventID = eventId };
                var results = await connection.QueryAsync(sqlQuery, param);

                return OkResponse(results, $"Chi tiết {results.Count()} sản phẩm trong event");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất: " + ex.Message });
            }
        }
    }
}