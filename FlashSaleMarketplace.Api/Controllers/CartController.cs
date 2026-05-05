using Microsoft.AspNetCore.Mvc;
using FlashSaleMarketplace.Api.Core;
using FlashSaleMarketplace.Api.DTOs;
using FlashSaleMarketplace.Api.Services;
using MongoDB.Bson;
using MongoDB.Driver;

namespace FlashSaleMarketplace.Api.Controllers
{
    public class CartController : BaseApiController
    {
        private readonly CartService _cartService;
        private readonly IMongoCollection<BsonDocument> _cartCollection;

        // Bơm CartService và MongoDB vào Controller
        public CartController(CartService cartService, IMongoDatabase mongoDatabase)
        {
            _cartService = cartService;
            _cartCollection = mongoDatabase.GetCollection<BsonDocument>("Carts");
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

        // =========================================================================
        // FIX 2: Abandoned Cart Report — Aggregation Pipeline Analytics
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

                var result = await _cartCollection
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