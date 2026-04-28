USE FlashSaleDB;
GO

SET NOCOUNT ON;

-- ==========================================
-- BƯỚC 1: DỌN DẸP ĐƠN HÀNG CŨ VÀ RESET ID
-- ==========================================
PRINT '1. Đang dọn dẹp đơn hàng cũ...';

DELETE FROM TransactionLogs;
DELETE FROM Payments;
DELETE FROM OrderDetails;
DELETE FROM Orders;

DELETE FROM Users;
DBCC CHECKIDENT ('Users', RESEED, 0);

-- ==========================================
-- BƯỚC 2: THU HẸP CHIẾN TRƯỜNG & CHÂM HÀNG (SPIKE TEST)
-- ==========================================
PRINT '2. Đang tạo chiến trường "5 món đồ HOT" và châm đầy hàng...';

-- A. Xóa bớt rác, chỉ giữ lại đúng 5 sản phẩm làm mồi nhử
WITH KeepCTE AS (
    SELECT TOP 5 FlashSaleItemID 
    FROM FlashSaleItems 
    ORDER BY FlashSaleItemID
)
DELETE FROM FlashSaleItems 
WHERE FlashSaleItemID NOT IN (SELECT FlashSaleItemID FROM KeepCTE);

-- B. Ép sự kiện luôn "Đang diễn ra"
UPDATE FlashSaleEvents 
SET StartTime = DATEADD(HOUR, -1, GETDATE()), 
    EndTime = DATEADD(HOUR, 5, GETDATE());

-- C. Cấp đúng 1000 suất cho 5 món này, reset số lượng đã bán
UPDATE FlashSaleItems 
SET SoldQuantity = 0, TotalAllocated = 1000;

-- D. Bơm kho vật lý dồi dào (5000) để đảm bảo an toàn, chỉ test tỷ lệ chọi của Flash Sale
UPDATE Inventory 
SET ReservedQuantity = 0, StockQuantity = 5000 
WHERE VariantID IN (SELECT VariantID FROM FlashSaleItems);

-- ==========================================
-- BƯỚC 3: TẠO LẠI 50,000 USER MỚI
-- ==========================================
PRINT '3. Đang tạo lại 50,000 User...';

WITH L0 AS (SELECT c FROM (VALUES(1),(1)) AS D(c)),
     L1 AS (SELECT 1 AS c FROM L0 AS A CROSS JOIN L0 AS B),
     L2 AS (SELECT 1 AS c FROM L1 AS A CROSS JOIN L1 AS B),
     L3 AS (SELECT 1 AS c FROM L2 AS A CROSS JOIN L2 AS B),
     L4 AS (SELECT 1 AS c FROM L3 AS A CROSS JOIN L3 AS B),
     L5 AS (SELECT 1 AS c FROM L4 AS A CROSS JOIN L4 AS B),
     Nums AS (SELECT ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS rownum FROM L5)
INSERT INTO Users (FullName, Email, Phone)
SELECT TOP (50000)
    'Khach Hang ' + CAST(rownum AS VARCHAR(10)), 
    'kh' + CAST(rownum AS VARCHAR(10)) + '@flashsale.com',
    '0900000000'
FROM Nums;

PRINT '---------------------------------';
PRINT 'HOÀN TẤT: Sẵn sàng cho bài Spike Test tranh giành 5 sản phẩm!';
GO