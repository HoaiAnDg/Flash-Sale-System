using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;

namespace FlashSaleMarketplace.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public abstract class BaseApiController : ControllerBase
    {
        protected IActionResult OkResponse<T>(T data, string message = "Success")
        {
            return Ok(ApiResponse<T>.Ok(data, message));
        }

        protected IActionResult ErrorResponse(string message, int statusCode = 400)
        {
            return StatusCode(statusCode, ApiResponse<object>.Fail(message));
        }
    }
}