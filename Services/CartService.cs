using FlashSaleMarketplace.Models;
using FlashSaleMarketplace.DTOs;
using MongoDB.Driver;

namespace FlashSaleMarketplace.Services
{
    public class CartService
    {
        private readonly IMongoCollection<Cart> _cartCollection;

        // Constructor inject MongoDB context (bạn cần cấu hình MongoClient ở Program.cs trước)
        public CartService(IMongoDatabase database)
        {
            _cartCollection = database.GetCollection<Cart>("Carts");
        }

        public async Task<bool> AddToCartAsync(AddToCartRequest request)
        {
            // 1. Tìm giỏ hàng đang active của User
            var filter = Builders<Cart>.Filter.Eq(c => c.UserId, request.UserId) &
                         Builders<Cart>.Filter.Eq(c => c.Status, "active");

            // 2. Chuẩn bị Item mới để nhúng (embed) vào mảng
            var newItem = new CartItem
            {
                ProductId = request.ProductId,
                Sku = request.Sku,
                ProductName = request.ProductName,
                UnitPrice = request.UnitPrice,
                Quantity = request.Quantity,
                AddedAt = DateTime.UtcNow
            };

            // 3. Sử dụng Atomic Operators ($push, $inc, $set) trong MỘT LỆNH DUY NHẤT
            var update = Builders<Cart>.Update
                .Push(c => c.Items, newItem)                                        // $push: Ném item vào mảng
                .Inc(c => c.TotalItems, request.Quantity)                           // $inc: Cộng dồn số lượng
                .Inc(c => c.TotalPrice, request.UnitPrice * request.Quantity)       // $inc: Cộng dồn tổng tiền
                .Set(c => c.UpdatedAt, DateTime.UtcNow)                             // $set: Cập nhật giờ update
                .SetOnInsert(c => c.Status, "active")                               // $setOnInsert: Chỉ set khi tạo mới
                .SetOnInsert(c => c.UserId, request.UserId);

            // 4. Bật cờ IsUpsert = true (Tìm không thấy thì tự tạo mới)
            var options = new UpdateOptions { IsUpsert = true };

            // 5. Thực thi ngay lập tức
            var result = await _cartCollection.UpdateOneAsync(filter, update, options);

            return result.IsAcknowledged;
        }
    }
}   