using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.DTOs;
using FlashSaleMarketplace.Api.Services;
using FlashSaleMarketplace.Api.Models; // Khai báo thêm Model Cart
using MongoDB.Driver; // Khai báo thêm thư viện MongoDB

namespace FlashSaleMarketplace.Api.Controllers
{
    [Route("api/cart")]
    [ApiController]
    public class CartController : BaseApiController
    {
        private readonly CartService _cartService;
        private readonly IMongoCollection<Cart> _cartCollection; // Bổ sung biến Mongo

        // Bơm cả CartService (cũ) và IMongoDatabase (mới) vào Controller
        public CartController(CartService cartService, IMongoDatabase mongoDatabase)
        {
            _cartService = cartService;
            _cartCollection = mongoDatabase.GetCollection<Cart>("Carts");
        }

        // ====================================================================
        // HÀM CŨ CỦA BẠN (Giữ nguyên kiến trúc Service)
        // ====================================================================
        [HttpPost("add")]
        public async Task<IActionResult> AddToCart([FromBody] AddToCartRequest request)
        {
            try
            {
                var success = await _cartService.AddToCartAsync(request);
                
                if (success)
                    return OkResponse(request, "Đã thêm vào giỏ hàng thần tốc trên MongoDB!");
                
                return StatusCode(500, new { success = false, message = "Lỗi khi ghi vào MongoDB" });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = ex.Message });
            }
        }

        // ====================================================================
        // HÀM MỚI 1: TẢI GIỎ HÀNG LÊN GIAO DIỆN KHI VỪA ĐĂNG NHẬP
        // ====================================================================
        [HttpGet("{userId}")]
        public async Task<IActionResult> GetCart(int userId)
        {
            try
            {
                var cart = await _cartCollection
                    .Find(c => c.UserId == userId && c.Status == "active")
                    .FirstOrDefaultAsync();

                // Nếu user chưa có giỏ hàng, trả về mảng rỗng []
                if (cart == null) 
                    return OkResponse(new List<object>(), "Giỏ hàng trống");

                return OkResponse(cart.Items, "Tải giỏ hàng thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = ex.Message });
            }
        }

        public class SyncCartRequest
        {
            public int UserId { get; set; }
            public List<CartItem> Items { get; set; } = new List<CartItem>();
        }

        // ====================================================================
        // HÀM MỚI 2: ĐỒNG BỘ NGUYÊN GIỎ HÀNG XUỐNG MONGO (CHỐNG MẤT DỮ LIỆU)
        // ====================================================================
        [HttpPost("sync")]
        public async Task<IActionResult> SyncCart([FromBody] SyncCartRequest req)
        {
            try
            {
                var cart = await _cartCollection
                    .Find(c => c.UserId == req.UserId && c.Status == "active")
                    .FirstOrDefaultAsync();

                if (cart == null)
                {
                    // Nếu chưa có giỏ hàng thì tạo mới
                    cart = new Cart { UserId = req.UserId, Status = "active", Items = req.Items };
                    await _cartCollection.InsertOneAsync(cart);
                }
                else
                {
                    // Nếu có rồi thì chép đè mảng Items (ghi nhận số lượng đã gộp từ UI)
                    var update = Builders<Cart>.Update.Set(c => c.Items, req.Items);
                    await _cartCollection.UpdateOneAsync(c => c.Id == cart.Id, update);
                }
                return OkResponse(null, "Đồng bộ giỏ hàng nền thành công!");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = ex.Message });
            }
        }
    }
}