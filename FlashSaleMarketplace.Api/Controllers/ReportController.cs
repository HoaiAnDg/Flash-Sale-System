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
    }
}