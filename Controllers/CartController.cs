using FlashSaleMarketplace.DTOs;
using FlashSaleMarketplace.Services;
using Microsoft.AspNetCore.Mvc;

namespace FlashSaleMarketplace.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class CartController : ControllerBase
    {
        private readonly CartService _cartService;

        public CartController(CartService cartService)
        {
            _cartService = cartService;
        }

        [HttpPost("add")]
        public async Task<IActionResult> AddToCart([FromBody] AddToCartRequest request)
        {
            try
            {
                var success = await _cartService.AddToCartAsync(request);
                
                if (success)
                    return Ok(new { message = "Đã thêm vào giỏ hàng thần tốc!", statusCode = 200 });
                
                return StatusCode(500, "Lỗi khi ghi vào MongoDB");
            }
            catch (Exception ex)
            {
                // Ghi log lỗi tại đây
                return StatusCode(500, ex.Message);
            }
        }
    }
}