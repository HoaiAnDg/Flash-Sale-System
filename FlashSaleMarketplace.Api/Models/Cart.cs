using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;
using System.Collections.Generic;

namespace FlashSaleMarketplace.Api.Models
{
    public class Cart
    {
        [BsonId]
        [BsonRepresentation(BsonType.ObjectId)]
        public string? Id { get; set; }

        [BsonElement("userId")]
        public int UserId { get; set; } 

        [BsonElement("status")]
        public string Status { get; set; } = "active";

        [BsonElement("items")]
        public List<CartItem> Items { get; set; } = new List<CartItem>();

        [BsonElement("lastModified")]
        public DateTime LastModified { get; set; } = DateTime.UtcNow;
    }

    [BsonIgnoreExtraElements]
    public class CartItem
    {
        [BsonElement("variantId")]
        public int VariantId { get; set; }

        [BsonElement("productName")]
        public string ProductName { get; set; } = string.Empty;

        [BsonElement("variantName")]
        public string VariantName { get; set; } = string.Empty;

        // [ĐÃ SỬA] Dùng chung biến Price cho cả hàng thường và hàng Sale
        [BsonElement("price")]
        public decimal Price { get; set; }

        // [BỔ SUNG] Cờ phân biệt hàng Flash Sale
        [BsonElement("isFlashSale")]
        public bool IsFlashSale { get; set; }

        [BsonElement("quantity")]
        public int Quantity { get; set; }

        // [BỔ SUNG] Lưu trạng thái tick chọn để F5 không bị mất
        [BsonElement("selected")]
        public bool Selected { get; set; } = true;
    }
}