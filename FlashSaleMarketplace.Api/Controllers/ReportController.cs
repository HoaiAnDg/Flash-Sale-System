using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;
using StackExchange.Redis;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class ReportController : BaseApiController
    {
        private readonly string _sqlConnectionString;
        private readonly IDatabase _redisDb;

        public ReportController(IConfiguration config, IConnectionMultiplexer redis)
        {
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
            _redisDb = redis.GetDatabase();
        }

        [HttpGet("top-selling")]
        public async Task<IActionResult> GetTopSelling()
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                
                // NÂNG CẤP TƯ DUY SQL:
                // 1. Dùng bảng tạm (CTE) NormalSales để tính số lượng bán từ các đơn hàng bình thường
                // 2. LEFT JOIN để lấy cả hàng thường lẫn hàng Sale
                // 3. Cộng dồn (NormalSold + SoldQuantity) để ra thứ hạng Top 5 chuẩn xác nhất
                var sqlQuery = @"
                    WITH NormalSales AS (
                        SELECT od.VariantID, ISNULL(SUM(od.Quantity), 0) AS NormalSold
                        FROM OrderDetails od
                        INNER JOIN Orders o ON od.OrderID = o.OrderID -- [FIX]: Bắt cầu sang bảng Orders
                        INNER JOIN ProductVariants pv ON od.VariantID = pv.VariantID
                        WHERE od.UnitPrice >= pv.Price AND o.Status != 2 -- [FIX]: Loại bỏ các đơn đã hủy
                        GROUP BY od.VariantID
                    )
                    SELECT TOP 5 
                        p.ProductName + ' - ' + pv.VariantName AS productName,
                        ISNULL(ns.NormalSold, 0) AS normalSold,
                        ISNULL(fsi.SoldQuantity, 0) AS flashSaleSold,
                        (ISNULL(i.StockQuantity, 0) + ISNULL(ns.NormalSold, 0) + ISNULL(fsi.SoldQuantity, 0)) AS totalStock,
                        (ISNULL(ns.NormalSold, 0) + ISNULL(fsi.SoldQuantity, 0)) AS sold,
                        pv.Price AS originalPrice,
                        ISNULL(fsi.FlashSalePrice, pv.Price) AS flashSalePrice, -- [FIX]: Tự động lấy giá gốc nếu không có Flash Sale
                        fse.StartTime AS startTime,
                        fse.EndTime AS endTime
                    FROM ProductVariants pv
                    INNER JOIN Products p ON pv.ProductID = p.ProductID
                    LEFT JOIN Inventory i ON pv.VariantID = i.VariantID
                    LEFT JOIN NormalSales ns ON pv.VariantID = ns.VariantID
                    LEFT JOIN FlashSaleItems fsi ON pv.VariantID = fsi.VariantID
                    LEFT JOIN FlashSaleEvents fse ON fsi.EventID = fse.EventID
                    ORDER BY sold DESC";

                var data = await connection.QueryAsync(sqlQuery);
                return OkResponse(data, "Lấy dữ liệu Top 5 toàn hệ thống thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất: " + ex.Message });
            }
        }

        // =========================================================================
        // HÀM CỦA BẠN: LẤY BÁO CÁO REALTIME (KẾT HỢP REDIS)
        // =========================================================================
        [HttpGet("realtime-summary")]
        public async Task<IActionResult> GetRealtimeSummary()
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                
                using var multi = await connection.QueryMultipleAsync("sp_GetRealtimeReport", commandType: System.Data.CommandType.StoredProcedure);
                var leaderboard = await multi.ReadAsync();
                var summary = await multi.ReadFirstOrDefaultAsync();

                // Đóng ngay Reader để giải phóng SQL Connection
                multi.Dispose(); 

                if (summary == null) return Ok(new { tongDaBan = 0, tongDoanhThu = "0 VND" });

                var activeVariants = await _redisDb.SetMembersAsync("fs:active_variants");
                int realTimeSoldFromRedis = 0;

                foreach (var variant in activeVariants)
                {
                    var stockStr = await _redisDb.StringGetAsync($"fs:stock:variant:{variant}");
                    if (stockStr.HasValue)
                    {
                        realTimeSoldFromRedis += (1000 - (int)stockStr);
                    }
                }

                return Ok(new
                {
                    tongDaBan = realTimeSoldFromRedis > 0 ? realTimeSoldFromRedis : (summary.TongDaBan ?? 0),
                    tongDoanhThu = summary.TongDoanhThu ?? "0 VND",
                    phutConLai = summary.PhutConLai ?? 0
                });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất realtime: " + ex.Message });
            }
        }

        // =========================================================================
        // FIX 7 (CỦA BẢO): Báo cáo tổng kết event — Window Functions + Analytics
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
        // BONUS (CỦA BẢO): Chi tiết từng sản phẩm trong event (Breakdown by variant)
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