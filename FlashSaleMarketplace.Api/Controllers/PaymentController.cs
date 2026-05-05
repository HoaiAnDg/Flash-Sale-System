using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;
using System.Data;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class PaymentController : BaseApiController
    {
        private readonly string _sqlConnectionString;

        public PaymentController(IConfiguration config)
        {
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
        }

        public class PaymentCallbackRequest
        {
            public Guid OrderId { get; set; }
            public string PaymentMethod { get; set; } = "VNPay";
        }

        [HttpPost("callback")]
        public async Task<IActionResult> PaymentCallback([FromBody] PaymentCallbackRequest request)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                await connection.OpenAsync();

                var parameters = new DynamicParameters();
                parameters.Add("@OrderID", request.OrderId);
                parameters.Add("@PaymentMethod", request.PaymentMethod);
                parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
                parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

                // Gọi SP Xác nhận thanh toán
                await connection.ExecuteAsync("sp_ConfirmPayment", parameters, commandType: CommandType.StoredProcedure);

                int resultCode = parameters.Get<int>("@ResultCode");
                string resultMsg = parameters.Get<string>("@ResultMsg");

                if (resultCode == 0) 
                    return OkResponse(null, resultMsg);
                
                return StatusCode(400, new { success = false, message = resultMsg });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi hệ thống: " + ex.Message });
            }
        }
    }
}