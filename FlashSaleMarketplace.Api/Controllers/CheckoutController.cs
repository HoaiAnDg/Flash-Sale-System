using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.Models;
using MongoDB.Driver;
using Dapper;
using Microsoft.Data.SqlClient;
using System.Data;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CheckoutController : BaseApiController
    {
        private readonly IMongoCollection<Cart> _cartCollection;
        private readonly string _sqlConnectionString;

        public CheckoutController(IMongoDatabase mongoDatabase, IConfiguration config)
        {
            _cartCollection = mongoDatabase.GetCollection<Cart>("Carts");
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
        }

        public class CheckoutRequest
        {
            public int UserId { get; set; }
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

                    await connection.ExecuteAsync("sp_CheckoutFlashSale", parameters, commandType: CommandType.StoredProcedure);

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

        [HttpPost("stress-test")]
        public async Task<IActionResult> StressTest([FromBody] CheckoutRequest request)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                await connection.OpenAsync();

                // Tự động tìm 1 món hàng đang có trong Flash Sale để dội bom
                var flashSaleItem = await connection.QueryFirstOrDefaultAsync<dynamic>(
                    "SELECT TOP 1 EventID, VariantID FROM FlashSaleItems"
                );

                if (flashSaleItem == null) 
                    return StatusCode(400, "Không có sự kiện Flash Sale nào");

                var parameters = new DynamicParameters();
                parameters.Add("@CustomerID", request.UserId);
                parameters.Add("@VariantID", (int)flashSaleItem.VariantID);
                parameters.Add("@EventID", (int)flashSaleItem.EventID);
                parameters.Add("@OrderID", dbType: DbType.Guid, direction: ParameterDirection.Output);
                parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
                parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

                // Đâm thẳng lệnh chốt đơn vào SQL Server
                await connection.ExecuteAsync("sp_CheckoutFlashSale", parameters, commandType: CommandType.StoredProcedure);

                int resultCode = parameters.Get<int>("@ResultCode");
                string resultMsg = parameters.Get<string>("@ResultMsg");

                if (resultCode == 0) return Ok(new { message = resultMsg });
                return StatusCode(400, new { message = resultMsg });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = "Sập SQL Server: " + ex.Message });
            }
        }
    }
}