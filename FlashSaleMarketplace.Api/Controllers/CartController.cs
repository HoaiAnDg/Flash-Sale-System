using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.DTOs;
using FlashSaleMarketplace.Api.Services;
using FlashSaleMarketplace.Api.Models; // Của bạn (Dùng cho Cart Model)
using MongoDB.Bson;                    // Của Bảo (Dùng cho Aggregation)
using MongoDB.Driver;                  // Dùng chung

namespace FlashSaleMarketplace.Api.Controllers
{
    [Route("api/cart")]
    [ApiController]
    public class CartController : BaseApiController
    {
        private readonly CartService _cartService;
        private readonly IMongoCollection<Cart> _cartCollection;          // Phục vụ luồng của bạn
        private readonly IMongoCollection<BsonDocument> _bsonCartCollection; // Phục vụ luồng của Bảo

        // Bơm CartService và IMongoDatabase vào Controller
        public CartController(CartService cartService, IMongoDatabase mongoDatabase)
        {
            _cartService = cartService;
            
            // Khởi tạo cả 2 góc nhìn cho cùng 1 bảng "Carts"
            _cartCollection = mongoDatabase.GetCollection<Cart>("Carts");
            _bsonCartCollection = mongoDatabase.GetCollection<BsonDocument>("Carts");
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

        // =========================================================================
        // FIX 2: Abandoned Cart Report — Aggregation Pipeline Analytics (Của Bảo)
        // =========================================================================
        [HttpGet("abandoned-report")]
        public async Task<IActionResult> GetAbandonedCarts()
        {
            try
            {
                // Thời gian cutoff: cart không bị modify trong 24 giờ = bị bỏ
                var cutoff = DateTime.UtcNow.AddHours(-24);

                var pipeline = new List<BsonDocument>
                {
                    // Stage 1: Match carts đang active nhưng không bị modify hơn 24h
                    new("$match", new BsonDocument
                    {
                        { "status", "active" },
                        { "lastModified", new BsonDocument("$lt", cutoff) }
                    }),
                    
                    // Stage 2: Unwind items array để tính toán từng variant
                    new("$unwind", "$items"),
                    
                    // Stage 3: Group lại theo VariantID để lấy thống kê
                    new("$group", new BsonDocument
                    {
                        { "_id", "$items.variantId" },
                        { "productName", new BsonDocument("$first", "$items.productName") },
                        { "variantName", new BsonDocument("$first", "$items.variantName") },
                        { "flashSalePrice", new BsonDocument("$first", "$items.flashSalePrice") },
                        { "totalAbandonedQty", new BsonDocument("$sum", "$items.quantity") },
                        { "potentialRevenueLoss", new BsonDocument("$sum",
                            new BsonDocument("$multiply", new BsonArray 
                            { 
                                "$items.quantity", 
                                "$items.flashSalePrice" 
                            }))
                        },
                        { "targetUserCount", new BsonDocument("$addToSet", "$userId") },
                        { "cartCount", new BsonDocument("$sum", 1) }
                    }),
                    
                    // Stage 4: Sort by potential revenue loss (descending)
                    new("$sort", new BsonDocument("potentialRevenueLoss", -1)),
                    
                    // Stage 5: Project lại để format response
                    new("$project", new BsonDocument
                    {
                        { "_id", 1 },
                        { "productName", 1 },
                        { "variantName", 1 },
                        { "flashSalePrice", 1 },
                        { "totalAbandonedQty", 1 },
                        { "potentialRevenueLoss", 1 },
                        { "uniqueUserCount", new BsonDocument("$size", "$targetUserCount") },
                        { "avgQtyPerCart", new BsonDocument("$divide", new BsonArray 
                            { 
                                "$totalAbandonedQty", 
                                "$cartCount" 
                            })
                        },
                        { "cartCount", 1 }
                    })
                };

                // Chạy pipeline trên collection BsonDocument để không bị lỗi Type
                var result = await _bsonCartCollection
                    .Aggregate<BsonDocument>(pipeline)
                    .ToListAsync();

                return OkResponse(result, 
                    $"Báo cáo {result.Count} sản phẩm bị bỏ giỏ hàng trong 24h qua");
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Lỗi: " + ex.Message });
            }
        }
    }
}