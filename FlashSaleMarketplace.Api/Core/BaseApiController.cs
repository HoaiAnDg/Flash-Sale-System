using Microsoft.AspNetCore.Mvc;

namespace FlashSaleMarketplace.Api.Core
{
    [ApiController]
    [Route("api/[controller]")]
    public abstract class BaseApiController : ControllerBase
    {
        // Hàm chuẩn hóa Data trả về cho toàn bộ hệ thống
        protected IActionResult OkResponse(object? data, string message = "Success")
        {
            return Ok(new
            {
                StatusCode = 200,
                Message = message,
                Data = data
            });
        }
    }
}