using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;

namespace FlashSaleMarketplace.Models
{
    public class Cart
    {
        [BsonId]
        [BsonRepresentation(BsonType.ObjectId)]
        public string? Id { get; set; }

        [BsonElement("userId")]
        public string UserId { get; set; } = null!;

        [BsonElement("status")]
        public string Status { get; set; } = "active";

        [BsonElement("items")]
        public List<CartItem> Items { get; set; } = new List<CartItem>(); // <-- Đây là phần Embedded (Nhúng)
    }

    // Class này được "nhúng" vào bên trong Cart
    public class CartItem
    {
        [BsonElement("productId")]
        public string ProductId { get; set; } = null!;

        [BsonElement("quantity")]
        public int Quantity { get; set; }
    }
}