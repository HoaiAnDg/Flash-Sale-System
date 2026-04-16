using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;

namespace FlashSaleMarketplace.Api.Models
{
    public class Cart
    {
        [BsonId]
        [BsonRepresentation(BsonType.ObjectId)]
        public string? Id { get; set; }

        [BsonElement("userId")]
        public int UserId { get; set; } // Khớp với INT của SQL Server

        [BsonElement("status")]
        public string Status { get; set; } = "active";

        [BsonElement("items")]
        public List<CartItem> Items { get; set; } = new List<CartItem>();
    }

    public class CartItem
    {
        [BsonElement("variantId")]
        public int VariantId { get; set; }

        [BsonElement("productName")]
        public string ProductName { get; set; } = string.Empty;

        [BsonElement("variantName")]
        public string VariantName { get; set; } = string.Empty;

        [BsonElement("flashSalePrice")]
        public decimal FlashSalePrice { get; set; }

        [BsonElement("quantity")]
        public int Quantity { get; set; }
    }
}