using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using Dapper;
using Microsoft.Data.SqlClient;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class UserController : BaseApiController
    {
        private readonly string _sqlConnectionString;

        public UserController(IConfiguration config)
        {
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
        }

        public class LoginRequest 
        { 
            public int UserId { get; set; } 
        }

        [HttpPost("login")]
        public async Task<IActionResult> Login([FromBody] LoginRequest req)
        {
            try
            {
                using var connection = new SqlConnection(_sqlConnectionString);
                
                // Truy vấn thẳng vào bảng Users để lấy thông tin
                var user = await connection.QueryFirstOrDefaultAsync(
                    "SELECT UserID, FullName, Email FROM Users WHERE UserID = @Id",
                    new { Id = req.UserId }
                );

                if (user == null) 
                    return StatusCode(404, new { success = false, message = "Không tìm thấy khách hàng có ID này!" });

                return OkResponse(user, "Đăng nhập thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi truy xuất dữ liệu: " + ex.Message });
            }
        }
    }
}