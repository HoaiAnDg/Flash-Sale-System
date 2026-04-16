using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.DTOs;
using FlashSaleMarketplace.Api.Services;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CartController : BaseApiController
    {
        private readonly CartService _cartService;

        // Bơm CartService vào Controller
        public CartController(CartService cartService)
        {
            _cartService = cartService;
        }

        [HttpPost("add")]
        public async Task<IActionResult> AddToCart([FromBody] AddToCartRequest request)
        {
            try
            {
                // Gọi thẳng xuống tầng Service để xử lý logic Mongo
                var success = await _cartService.AddToCartAsync(request);
                
                if (success)
                    return OkResponse(request, "Đã thêm vào giỏ hàng thần tốc trên MongoDB!");
                
                return StatusCode(500, "Lỗi khi ghi vào MongoDB");
            }
            catch (Exception ex)
            {
                return StatusCode(500, ex.Message);
            }
        }
    }
}