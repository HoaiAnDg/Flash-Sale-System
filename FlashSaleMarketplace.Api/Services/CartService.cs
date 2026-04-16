using FlashSaleMarketplace.Api.Models;
using FlashSaleMarketplace.Api.DTOs;
using MongoDB.Driver;

namespace FlashSaleMarketplace.Api.Services
{
    public class CartService
    {
        private readonly IMongoCollection<Cart> _cartCollection;

        public CartService(IMongoDatabase database)
        {
            _cartCollection = database.GetCollection<Cart>("Carts");
        }

        public async Task<bool> AddToCartAsync(AddToCartRequest request)
        {
            // 1. Tìm giỏ hàng đang active của User
            var filter = Builders<Cart>.Filter.Eq(c => c.UserId, request.UserId) &
                         Builders<Cart>.Filter.Eq(c => c.Status, "active");

            // 2. Chuẩn bị Item mới để nhúng vào mảng
            var newItem = new CartItem
            {
                VariantId = request.VariantId,
                ProductName = request.ProductName,
                VariantName = request.VariantName,
                FlashSalePrice = request.FlashSalePrice,
                Quantity = request.Quantity
            };

            // 3. Sử dụng Atomic Operators ($push, $setOnInsert)
            var update = Builders<Cart>.Update
                .Push(c => c.Items, newItem)
                .SetOnInsert(c => c.Status, "active")
                .SetOnInsert(c => c.UserId, request.UserId);

            // 4. Upsert: Tìm không thấy thì tự tạo mới
            var options = new UpdateOptions { IsUpsert = true };

            var result = await _cartCollection.UpdateOneAsync(filter, update, options);

            return result.IsAcknowledged;
        }
    }
}