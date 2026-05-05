namespace FlashSaleMarketplace.Api.DTOs
{
    public class AddToCartRequest
    {
        public int UserId { get; set; }
        public int VariantId { get; set; }
        public string ProductName { get; set; } = string.Empty;
        public string VariantName { get; set; } = string.Empty;
        public decimal FlashSalePrice { get; set; }
        public int Quantity { get; set; }
    }
}