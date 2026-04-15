-- =========================================
-- Index tối ưu truy vấn
-- =========================================
USE FlashSaleDB;
GO

-- PRODUCT
CREATE INDEX IX_ProductVariants_ProductID 
ON ProductVariants(ProductID);

-- INVENTORY (MERGED - QUAN TRỌNG NHẤT)
CREATE UNIQUE INDEX IX_Inventory_VariantID 
ON Inventory(VariantID)
INCLUDE (StockQuantity, ReservedQuantity, ReservedUntil);

-- FLASH SALE
CREATE INDEX IX_FS_Event_Variant 
ON FlashSaleItems(EventID, VariantID)
INCLUDE (FlashSalePrice, TotalAllocated, SoldQuantity, SaleLimit);

CREATE INDEX IX_FS_Variant 
ON FlashSaleItems(VariantID);

-- ORDERS
CREATE INDEX IX_Orders_CustomerID 
ON Orders(CustomerID)
INCLUDE (Status, OrderDate);

CREATE INDEX IX_OD_OrderID 
ON OrderDetails(OrderID);

CREATE INDEX IX_Payments_OrderID 
ON Payments(OrderID);

-- TIME FILTER
CREATE INDEX IX_FlashSaleEvents_Time 
ON FlashSaleEvents(StartTime, EndTime);

-- AUTO CANCEL
CREATE INDEX IX_Inventory_ReservedUntil 
ON Inventory(ReservedUntil)
INCLUDE (VariantID, ReservedQuantity)
WHERE ReservedUntil IS NOT NULL;