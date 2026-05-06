USE master;
GO

-- =========================================
-- 0. XÓA DATABASE CŨ (NẾU CÓ) BẰNG CÁCH "ĐÁ" TẤT CẢ USER RA NGOÀI
-- =========================================
IF EXISTS (SELECT name FROM sys.databases WHERE name = N'FlashSaleDB')
BEGIN
    PRINT N'Dang xoa FlashSaleDB cu...';
    -- 1. "Đá" tất cả các kết nối đang cắm vào DB này ra ngoài một cách thô bạo
    ALTER DATABASE FlashSaleDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    -- 2. Đợi 1 giây cho chắc ăn
    WAITFOR DELAY '00:00:01'; 
    -- 3. Xóa sổ toàn bộ
    DROP DATABASE FlashSaleDB;
END
GO

-- 4. Ép SQL phải lưu lại trạng thái hệ thống trước khi qua bước tiếp theo
CHECKPOINT; 
GO

-- =========================================
-- TẠO MỚI DATABASE CLEAN 100%
-- =========================================
CREATE DATABASE FlashSaleDB;
GO

-- Đợi 1 giây để OS cấp phát file vật lý cho DB mới
WAITFOR DELAY '00:00:01';
GO

USE FlashSaleDB;
GO

-- =========================================
-- 1. USERS (Thông tin khách hàng)
-- =========================================
CREATE TABLE Users (
    UserID INT PRIMARY KEY IDENTITY(1,1), -- ID người dùng (tự tăng)
    FullName NVARCHAR(150),               -- Tên đầy đủ
    Email NVARCHAR(150) UNIQUE,           -- Email (duy nhất)
    Phone NVARCHAR(20),                   -- Số điện thoại
    CreatedAt DATETIME DEFAULT GETDATE()  -- Ngày tạo tài khoản
);

-- =========================================
-- 2. CATEGORIES (Danh mục - dạng cây)
-- =========================================
CREATE TABLE Categories (
    CategoryID INT PRIMARY KEY IDENTITY(1,1), -- ID danh mục
    CategoryName NVARCHAR(100) NOT NULL,      -- Tên danh mục
    ParentID INT NULL,                        -- ID danh mục cha (tạo cây)

    -- Liên kết đệ quy (self-reference)
    CONSTRAINT FK_Category_Parent FOREIGN KEY (ParentID) REFERENCES Categories(CategoryID)
);

-- =========================================
-- 3. PRODUCTS (Cache nhẹ từ MongoDB)
-- =========================================
CREATE TABLE Products (
    ProductID INT PRIMARY KEY IDENTITY(1,1), -- ID sản phẩm
    ProductName NVARCHAR(200) NOT NULL,      -- Tên sản phẩm
    CategoryID INT,                          -- Thuộc danh mục nào
    Brand NVARCHAR(100),                     -- Thương hiệu
    CreatedAt DATETIME DEFAULT GETDATE(),    -- Ngày tạo

    CONSTRAINT FK_Product_Category FOREIGN KEY (CategoryID) REFERENCES Categories(CategoryID)
);

-- =========================================
-- 4. PRODUCT VARIANTS (Biến thể sản phẩm)
-- =========================================
CREATE TABLE ProductVariants (
    VariantID INT PRIMARY KEY IDENTITY(1,1), -- ID biến thể
    ProductID INT NOT NULL,                  -- Thuộc sản phẩm nào
    SKU NVARCHAR(50) UNIQUE NOT NULL,        -- Mã SKU (duy nhất)
    VariantName NVARCHAR(200),               -- Tên biến thể (VD: Size M, màu đỏ)
    Price DECIMAL(18,2) NOT NULL,            -- Giá gốc

    CONSTRAINT FK_Variant_Product FOREIGN KEY (ProductID) REFERENCES Products(ProductID),
    CONSTRAINT CHK_Price_Positive CHECK (Price >= 0) -- Giá không âm
);

-- =========================================
-- 5. INVENTORY (Quản lý tồn kho)
-- =========================================
CREATE TABLE Inventory (
    InventoryID INT PRIMARY KEY IDENTITY(1,1), -- ID tồn kho
    VariantID INT UNIQUE NOT NULL,             -- Mỗi variant có 1 record tồn kho
    StockQuantity INT NOT NULL DEFAULT 0,      -- Tổng số lượng trong kho
    ReservedQuantity INT NOT NULL DEFAULT 0,   -- Số lượng đã giữ chỗ (flash sale)
    ReservedUntil DATETIME NULL,               -- Thời gian giữ chỗ hết hạn
    Version ROWVERSION,                        -- Dùng cho optimistic locking

    CONSTRAINT FK_Inventory_Variant FOREIGN KEY (VariantID) REFERENCES ProductVariants(VariantID),
    CONSTRAINT CHK_Stock_Positive CHECK (StockQuantity >= 0),
    CONSTRAINT CHK_Reserved_Positive CHECK (ReservedQuantity >= 0),
    -- Đảm bảo không giữ chỗ quá số lượng tồn
    CONSTRAINT CHK_Stock_Logic CHECK (StockQuantity >= ReservedQuantity)
);

-- =========================================
-- 6. FLASH SALE EVENTS (Sự kiện flash sale)
-- =========================================
CREATE TABLE FlashSaleEvents (
    EventID INT PRIMARY KEY IDENTITY(1,1), -- ID sự kiện
    Title NVARCHAR(200) NOT NULL,          -- Tên sự kiện
    StartTime DATETIME NOT NULL,           -- Thời gian bắt đầu
    EndTime DATETIME NOT NULL,             -- Thời gian kết thúc

    -- Đảm bảo thời gian hợp lệ
    CONSTRAINT CHK_Time CHECK (EndTime > StartTime)
);

-- =========================================
-- 7. FLASH SALE ITEMS (Sản phẩm trong flash sale)
-- =========================================
CREATE TABLE FlashSaleItems (
    FlashSaleItemID INT PRIMARY KEY IDENTITY(1,1), -- ID item
    EventID INT NOT NULL,                          -- Thuộc event nào
    VariantID INT NOT NULL,                        -- Variant nào được sale
    FlashSalePrice DECIMAL(18,2) NOT NULL,         -- Giá flash sale
    SaleLimit INT DEFAULT 1,                       -- Giới hạn mỗi user
    TotalAllocated INT NOT NULL,                   -- Tổng số lượng được bán
    SoldQuantity INT NOT NULL DEFAULT 0,           -- Đã bán bao nhiêu
    Version ROWVERSION,                            -- Chống race condition

    CONSTRAINT FK_FS_Event FOREIGN KEY (EventID) REFERENCES FlashSaleEvents(EventID),
    CONSTRAINT FK_FS_Variant FOREIGN KEY (VariantID) REFERENCES ProductVariants(VariantID),
    -- 1 variant chỉ xuất hiện 1 lần trong 1 event
    CONSTRAINT UQ_Event_Variant UNIQUE (EventID, VariantID),
    CONSTRAINT CHK_FlashPrice_Positive CHECK (FlashSalePrice >= 0),
    -- Không bán vượt quá số lượng được cấp
    CONSTRAINT CHK_Sale_Logic CHECK (SoldQuantity <= TotalAllocated)
);

-- =========================================
-- 8. ORDERS (Đơn hàng)
-- =========================================
CREATE TABLE Orders (
    OrderID UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(), -- ID đơn hàng (GUID)
    CustomerID INT NOT NULL,                              -- Người mua
    TotalAmount DECIMAL(18,2) DEFAULT 0,                  -- Tổng tiền
    OrderDate DATETIME DEFAULT GETDATE(),                 -- Ngày đặt hàng
    Status TINYINT DEFAULT 0,                             -- 0: Pending, 1: Success, 2: Cancel

    CONSTRAINT FK_Orders_User FOREIGN KEY (CustomerID) REFERENCES Users(UserID),
    CONSTRAINT CHK_TotalAmount_Positive CHECK (TotalAmount >= 0)
);

-- =========================================
-- 9. ORDER DETAILS (Chi tiết đơn hàng - snapshot)
-- =========================================
CREATE TABLE OrderDetails (
    OrderDetailID INT PRIMARY KEY IDENTITY(1,1),
    OrderID UNIQUEIDENTIFIER NOT NULL,
    VariantID INT NOT NULL,

    -- Snapshot từ Mongo (tránh phụ thuộc dữ liệu bên ngoài)
    ProductName NVARCHAR(200),
    VariantName NVARCHAR(200),
    Quantity INT NOT NULL,                -- Số lượng mua
    UnitPrice DECIMAL(18,2),              -- Giá tại thời điểm mua

    CONSTRAINT FK_OD_Order FOREIGN KEY (OrderID) REFERENCES Orders(OrderID),
    CONSTRAINT FK_OD_Variant FOREIGN KEY (VariantID) REFERENCES ProductVariants(VariantID),
    CONSTRAINT CHK_Quantity_Positive CHECK (Quantity > 0)
);

-- =========================================
-- 10. PAYMENTS (Thanh toán)
-- =========================================
CREATE TABLE Payments (
    PaymentID INT PRIMARY KEY IDENTITY(1,1),
    OrderID UNIQUEIDENTIFIER NOT NULL, -- Đơn hàng liên quan
    Amount DECIMAL(18,2) NOT NULL,     -- Số tiền thanh toán
    PaymentMethod NVARCHAR(50),        -- Phương thức (Momo, VNPay,...)
    Status TINYINT DEFAULT 0,          -- 0: Pending, 1: Success, 2: Failed
    CreatedAt DATETIME DEFAULT GETDATE(),

    CONSTRAINT FK_Payment_Order FOREIGN KEY (OrderID) REFERENCES Orders(OrderID),
    CONSTRAINT CHK_Payment_Amount CHECK (Amount >= 0)
);

-- =========================================
-- 11. TRANSACTION LOG (Dùng cho Saga pattern)
-- =========================================
CREATE TABLE TransactionLogs (
    LogID INT PRIMARY KEY IDENTITY(1,1),
    OrderID UNIQUEIDENTIFIER,     -- Đơn hàng liên quan
    Step NVARCHAR(100),           -- Bước xử lý (Reserve, Payment,...)
    Status TINYINT,               -- 0: Pending, 1: Success, 2: Failed
    CreatedAt DATETIME DEFAULT GETDATE()
);
GO

    USE FlashSaleDB;
GO

-- =================================================================================
-- TUẦN 2: SINH DỮ LIỆU LỚN VÀ TỐI ƯU HÓA
-- Mục tiêu:
--   [1] Sinh 1,000,000+ SKU  (50,000 Products x 20 Variants)
--   [2] Sinh pool 50,000 Flash Sale (TABLESAMPLE, không ORDER BY NEWID)
--   [3] Recursive CTE hiển thị cây danh mục
-- =================================================================================

-- ─────────────────────────────────────────────────────────────────────────────────
-- BƯỚC 0: Tắt constraint để INSERT nhanh hơn
-- ─────────────────────────────────────────────────────────────────────────────────
ALTER TABLE Products          NOCHECK CONSTRAINT ALL;
ALTER TABLE ProductVariants   NOCHECK CONSTRAINT ALL;
ALTER TABLE Inventory         NOCHECK CONSTRAINT ALL;
ALTER TABLE FlashSaleItems    NOCHECK CONSTRAINT ALL;
GO

-- Xóa dữ liệu cũ (đúng thứ tự FK)
DELETE FROM FlashSaleItems;
DELETE FROM FlashSaleEvents;
DELETE FROM Inventory;
DELETE FROM ProductVariants;
DELETE FROM Products;
DELETE FROM Categories;
GO

-- Reset IDENTITY
DBCC CHECKIDENT ('FlashSaleItems',   RESEED, 0);
DBCC CHECKIDENT ('FlashSaleEvents',  RESEED, 0);
DBCC CHECKIDENT ('Inventory',        RESEED, 0);
DBCC CHECKIDENT ('ProductVariants',  RESEED, 0);
DBCC CHECKIDENT ('Products',         RESEED, 0);
DBCC CHECKIDENT ('Categories',       RESEED, 0);
GO

-- =================================================================================
-- PHẦN 1: DANH MỤC (CATEGORIES) - Cấu trúc cây 2 cấp
-- =================================================================================
SET IDENTITY_INSERT Categories ON;
GO

INSERT INTO Categories (CategoryID, CategoryName, ParentID) VALUES
-- Cấp 1 (Cha)
(1,  N'PC - Máy tính bàn',       NULL),
(2,  N'Laptop',                   NULL),
(3,  N'Apple',                    NULL),
(4,  N'Màn hình máy tính',        NULL),
(5,  N'Linh kiện máy tính',       NULL),
(6,  N'Phụ kiện máy tính',        NULL),
(7,  N'Gaming Gear',              NULL),
(8,  N'Điện thoại - Tablet',      NULL),
(9,  N'Thiết bị âm thanh',        NULL),
(10, N'Thiết bị văn phòng',       NULL),
(11, N'Điện máy - Điện gia dụng', NULL),
-- Cấp 2 (Con)
(101, N'PC Gaming',                      1),
(102, N'PC Đồ họa',                      1),
(103, N'PC Văn phòng',                   1),
(201, N'Laptop Gaming',                  2),
(202, N'Laptop Đồ họa & Kỹ thuật',       2),
(203, N'Laptop Mỏng nhẹ & Cao cấp',      2),
(204, N'Laptop Sinh viên & Văn phòng',   2),
(301, N'iPhone',                         3),
(302, N'iPad',                           3),
(303, N'MacBook',                        3),
(304, N'Apple Watch',                    3),
(305, N'AirPods',                        3),
(501, N'CPU - Bộ vi xử lý',             5),
(502, N'RAM - Bộ nhớ trong',            5),
(503, N'SSD / HDD - Ổ cứng',           5),
(504, N'VGA - Card màn hình',           5),
(505, N'Mainboard - Bo mạch chủ',       5),
(701, N'Bàn phím cơ',                   7),
(702, N'Chuột gaming',                  7),
(703, N'Tai nghe gaming',               7),
(801, N'Samsung',                       8),
(802, N'Xiaomi',                        8),
(803, N'OPPO',                          8);
GO

SET IDENTITY_INSERT Categories OFF;
GO

-- =================================================================================
-- PHẦN 2: BẢNG TẠM DỮ LIỆU MẪU
-- =================================================================================

-- ── #ProductTemplates ────────────────────────────────────────────────────────────
IF OBJECT_ID('tempdb..#ProductTemplates') IS NOT NULL DROP TABLE #ProductTemplates;
CREATE TABLE #ProductTemplates (
    ID                  INT IDENTITY(1,1) PRIMARY KEY,
    CategoryID          INT           NOT NULL,
    Brand               NVARCHAR(100) NOT NULL,
    ProductNameTemplate NVARCHAR(200) NOT NULL,
    SKUPrefix           NVARCHAR(10)  NOT NULL,
    BasePrice           DECIMAL(18,2) NOT NULL
);
GO

INSERT INTO #ProductTemplates (CategoryID, Brand, ProductNameTemplate, SKUPrefix, BasePrice) VALUES
(201, N'ASUS ROG',      N'Laptop Gaming ASUS ROG Strix G16',           N'ASUSG',     35000000),
(201, N'Acer Predator', N'Laptop Gaming Acer Predator Helios',          N'ACERH',     45000000),
(202, N'Dell XPS',      N'Laptop Dell XPS 15',                          N'DELLXPS',   50000000),
(203, N'LG Gram',       N'Laptop LG Gram 2024 16 inch',                 N'LGGR',      30000000),
(301, N'Apple',         N'iPhone 15 Pro Max',                           N'IP15PM',    32000000),
(302, N'Apple',         N'iPad Pro M4 11 inch',                         N'IPADM4',    28000000),
(303, N'Apple',         N'MacBook Air M3 13 inch',                      N'MBAIRM3',   27000000),
(501, N'Intel',         N'CPU Intel Core i9-14900K',                    N'I914900K',  15000000),
(501, N'AMD',           N'CPU AMD Ryzen 9 7950X3D',                     N'R97950X3D', 16000000),
(504, N'NVIDIA',        N'VGA GeForce RTX 4090',                        N'RTX4090',   55000000),
(504, N'AMD',           N'VGA Radeon RX 7900 XTX',                      N'RX7900XTX', 28000000),
(701, N'Razer',         N'Ban phim co Razer BlackWidow V4',             N'RAZERBW',    4500000),
(702, N'Logitech',      N'Chuot gaming Logitech G Pro X Superlight',    N'LOGIPROX',   3200000);
GO

-- ── #VariantAttributes ───────────────────────────────────────────────────────────
IF OBJECT_ID('tempdb..#VariantAttributes') IS NOT NULL DROP TABLE #VariantAttributes;
CREATE TABLE #VariantAttributes (
    ID            INT IDENTITY(1,1) PRIMARY KEY,
    AttrType      NVARCHAR(50)  NOT NULL,
    AttrName      NVARCHAR(50)  NOT NULL,
    PriceModifier DECIMAL(18,2) NOT NULL DEFAULT 0
);
GO

INSERT INTO #VariantAttributes (AttrType, AttrName, PriceModifier) VALUES
(N'Color',   N'Den',                0),
(N'Color',   N'Trang',        100000),
(N'Color',   N'Bac',          200000),
(N'Color',   N'Xanh',         300000),
(N'Color',   N'Titan',       1000000),
(N'Storage', N'128GB',              0),
(N'Storage', N'256GB',       1500000),
(N'Storage', N'512GB',       3000000),
(N'Storage', N'1TB',         5000000),
(N'RAM',     N'8GB',                0),
(N'RAM',     N'16GB',        2000000),
(N'RAM',     N'32GB',        4500000),
(N'RAM',     N'64GB',        8000000);
GO

-- ── #GeneratedProducts: lưu ProductID + BasePrice + SKUPrefix cùng lúc ──────────
IF OBJECT_ID('tempdb..#GeneratedProducts') IS NOT NULL DROP TABLE #GeneratedProducts;
CREATE TABLE #GeneratedProducts (
    ProductID   INT            NOT NULL PRIMARY KEY,
    BasePrice   DECIMAL(18,2)  NULL,
    SKUPrefix   NVARCHAR(10)   NULL
);
GO

-- ── #GeneratedVariants: lưu VariantID để sinh Inventory ─────────────────────────
IF OBJECT_ID('tempdb..#GeneratedVariants') IS NOT NULL DROP TABLE #GeneratedVariants;
CREATE TABLE #GeneratedVariants (
    VariantID INT NOT NULL PRIMARY KEY
);
GO

-- =================================================================================
-- PHẦN 3: SINH 50,000 PRODUCTS
-- =================================================================================
BEGIN TRY
    DECLARE @product_batch_size INT;
    DECLARE @template_count     INT;
    DECLARE @rows_per_template  INT;
    DECLARE @cnt_products       INT;

    SET @product_batch_size = 50000;
    SELECT @template_count = COUNT(*) FROM #ProductTemplates;

    IF @template_count = 0
    BEGIN
        RAISERROR(N'#ProductTemplates rong. Dung thuc thi.', 16, 1);
    END;

    SET @rows_per_template = @product_batch_size / @template_count; -- = 50000/13 ≈ 3846

    BEGIN TRANSACTION;

    -- ─── Bước 1a: INSERT Products, OUTPUT ProductID vào #GeneratedProducts ───────
    -- Dùng NumberTally (CROSS JOIN spt_values) để nhân bản template
    ;WITH NumberTally AS (
        SELECT TOP (@rows_per_template)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
        FROM master.dbo.spt_values AS a
        CROSS JOIN master.dbo.spt_values AS b
    )
    INSERT INTO Products (ProductName, CategoryID, Brand, CreatedAt)
    OUTPUT INSERTED.ProductID INTO #GeneratedProducts (ProductID)
    SELECT
        t.ProductNameTemplate + N' Gen ' + CAST(nt.N AS NVARCHAR(10)),
        t.CategoryID,
        t.Brand,
        GETDATE()
    FROM NumberTally nt
    CROSS JOIN #ProductTemplates t;

    -- ─── Bước 1b: Gán BasePrice + SKUPrefix cho #GeneratedProducts via JOIN ───────
    UPDATE gp
    SET
        gp.BasePrice = t.BasePrice,
        gp.SKUPrefix = t.SKUPrefix
    FROM #GeneratedProducts gp
    INNER JOIN Products p
        ON p.ProductID = gp.ProductID
    INNER JOIN #ProductTemplates t
        ON p.Brand      = t.Brand
       AND p.CategoryID = t.CategoryID;

    SELECT @cnt_products = COUNT(*) FROM #GeneratedProducts WHERE BasePrice IS NOT NULL;
    PRINT N'BUOC 1 HOAN THANH: Da sinh ' + CAST(@cnt_products AS NVARCHAR(20)) + N' san pham co day du thong tin.';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT N'LOI o Phan 3 (Sinh Products). Da rollback.';
    SELECT
        ERROR_NUMBER()    AS ErrorNumber,
        ERROR_SEVERITY()  AS ErrorSeverity,
        ERROR_STATE()     AS ErrorState,
        ERROR_LINE()      AS ErrorLine,
        ERROR_MESSAGE()   AS ErrorMessage;
END CATCH;
GO

PRINT N'=== Ket thuc Phan 3: Sinh Products ===';
GO

-- =================================================================================
-- PHẦN 4: SINH 1,000,000 VARIANTS (SKU) + INVENTORY
-- =================================================================================
BEGIN TRY
    DECLARE @variants_per_product INT;
    DECLARE @cnt_variants         INT;
    DECLARE @cnt_inv              INT;

    SET @variants_per_product = 20; -- 50,000 products x 20 = 1,000,000 SKU

    BEGIN TRANSACTION;

    -- ─── Bước 2: Sinh biến thể (SKU) ────────────────────────────────────────────
    INSERT INTO ProductVariants (ProductID, SKU, VariantName, Price)
    OUTPUT INSERTED.VariantID INTO #GeneratedVariants (VariantID)
    SELECT
        ProductID,
        SKU,
        VariantName,
        FinalPrice
    FROM (
        -- Subquery tạo toàn bộ combo và đánh số thứ tự ngẫu nhiên
        SELECT
            gp.ProductID,
            -- SKU = PREFIX-PRODUCTID-HASH(8 ký tự) → duy nhất tuyệt đối
            UPPER(
                gp.SKUPrefix
                + N'-' + CAST(gp.ProductID AS VARCHAR(10))
                + N'-' + SUBSTRING(
                    CONVERT(VARCHAR(32),
                        HASHBYTES('MD5',
                              CAST(gp.ProductID AS VARCHAR(10))
                            + va_s.AttrName
                            + va_r.AttrName
                            + va_c.AttrName),
                        2),
                    1, 8)
            ) AS SKU,
            -- Tên biến thể
            LEFT(p.ProductName, 50)
                + N' [' + va_s.AttrName
                + N'/' + va_r.AttrName
                + N'/' + va_c.AttrName + N']' AS VariantName,
            -- Giá = BasePrice + tổng modifier
            gp.BasePrice
                + va_s.PriceModifier
                + va_r.PriceModifier
                + va_c.PriceModifier AS FinalPrice,
            -- ROW_NUMBER ngẫu nhiên để chọn 20 combo/product
            ROW_NUMBER() OVER (PARTITION BY gp.ProductID ORDER BY NEWID()) AS rn
        FROM #GeneratedProducts gp
        INNER JOIN Products p
            ON p.ProductID = gp.ProductID
        CROSS JOIN (SELECT AttrName, PriceModifier FROM #VariantAttributes WHERE AttrType = N'Storage') va_s
        CROSS JOIN (SELECT AttrName, PriceModifier FROM #VariantAttributes WHERE AttrType = N'RAM')     va_r
        CROSS JOIN (SELECT AttrName, PriceModifier FROM #VariantAttributes WHERE AttrType = N'Color')   va_c
    ) AS VariantSet
    WHERE rn <= @variants_per_product; -- Giới hạn 20 biến thể / sản phẩm

    SELECT @cnt_variants = COUNT(*) FROM #GeneratedVariants;
    PRINT N'BUOC 2 HOAN THANH: Da sinh ' + CAST(@cnt_variants AS NVARCHAR(20)) + N' SKU.';

    -- ─── Bước 3: Sinh Inventory ──────────────────────────────────────────────────
    INSERT INTO Inventory (VariantID, StockQuantity, ReservedQuantity)
    SELECT
        VariantID,
        100 + (ABS(CHECKSUM(NEWID())) % 401),  -- Tồn kho 100~500
        0
    FROM #GeneratedVariants;

    SELECT @cnt_inv = COUNT(*) FROM #GeneratedVariants;
    PRINT N'BUOC 3 HOAN THANH: Da sinh Inventory cho ' + CAST(@cnt_inv AS NVARCHAR(20)) + N' bien the.';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT N'LOI o Phan 4 (Sinh Variants/Inventory). Da rollback.';
    SELECT
        ERROR_NUMBER()    AS ErrorNumber,
        ERROR_SEVERITY()  AS ErrorSeverity,
        ERROR_STATE()     AS ErrorState,
        ERROR_LINE()      AS ErrorLine,
        ERROR_MESSAGE()   AS ErrorMessage;
END CATCH;
GO

PRINT N'=== HOAN THANH: Sinh 1,000,000+ SKU va Inventory ===';
GO

-- =================================================================================
-- PHẦN 5: FLASH SALE — Pool 50,000 sản phẩm
-- Kỹ thuật: TABLESAMPLE thay ORDER BY NEWID() → nhanh hơn ~100x trên 1M rows
-- TABLESAMPLE(10 PERCENT) lấy ~100,000 rows → TOP 50,000 đủ pool
-- =================================================================================
BEGIN TRY
    DECLARE @event_id        INT;
    DECLARE @flash_sale_size INT;
    DECLARE @cnt_flash       INT;

    SET @flash_sale_size = 50000;

    BEGIN TRANSACTION;

    -- Tạo sự kiện Flash Sale
    INSERT INTO FlashSaleEvents (Title, StartTime, EndTime)
    VALUES (
        N'Sieu Sale Cong Nghe Cuoi Nam',
        DATEADD(HOUR, 1, GETDATE()),
        DATEADD(HOUR, 3, GETDATE())
    );

    SET @event_id = SCOPE_IDENTITY();

    -- Thêm 50,000 SKU vào pool Flash Sale
    -- DÙNG TABLESAMPLE → lấy mẫu theo page, cực nhanh
    INSERT INTO FlashSaleItems (EventID, VariantID, FlashSalePrice, SaleLimit, TotalAllocated)
    SELECT TOP (@flash_sale_size)
        @event_id,
        pv.VariantID,
        CAST(pv.Price * 0.70 AS DECIMAL(18,2)),   -- Giảm 30%
        1,                                          -- Giới hạn 1 suất/user
        10 + (ABS(CHECKSUM(NEWID())) % 41)          -- 10~50 suất/sản phẩm
    FROM ProductVariants pv TABLESAMPLE (10 PERCENT)
    WHERE pv.Price > 1000000;                       -- Chỉ sale sản phẩm có giá trị

    SELECT @cnt_flash = COUNT(*) FROM FlashSaleItems WHERE EventID = @event_id;
    PRINT N'FLASH SALE: Da them ' + CAST(@cnt_flash AS NVARCHAR(20))
        + N' san pham vao pool (EventID = ' + CAST(@event_id AS NVARCHAR(10)) + N').';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT N'LOI o Phan 5 (Sinh Flash Sale). Da rollback.';
    SELECT
        ERROR_NUMBER()   AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE()    AS ErrorState,
        ERROR_LINE()     AS ErrorLine,
        ERROR_MESSAGE()  AS ErrorMessage;
END CATCH;
GO

-- Bật lại tất cả constraint
ALTER TABLE Products        CHECK CONSTRAINT ALL;
ALTER TABLE ProductVariants CHECK CONSTRAINT ALL;
ALTER TABLE Inventory       CHECK CONSTRAINT ALL;
ALTER TABLE FlashSaleItems  CHECK CONSTRAINT ALL;
GO

PRINT N'=== TAT CA CONSTRAINT DA BAT LAI. SINH DU LIEU HOAN TAT ===';
GO

-- =================================================================================
-- PHẦN 6: RECURSIVE CTE — Hiển thị cây danh mục sản phẩm
-- =================================================================================
--
-- GIẢI THÍCH RECURSIVE CTE:
--
-- Cấu trúc gồm 2 phần nối bằng UNION ALL:
--
-- [1] ANCHOR MEMBER (chạy 1 lần duy nhất):
--     Lấy các danh mục gốc (ParentID IS NULL), gán Level = 0.
--
-- [2] RECURSIVE MEMBER (chạy lặp lại):
--     JOIN Categories với chính CTE để tìm danh mục CON của vòng trước.
--     Tăng Level thêm 1 mỗi vòng. Dừng khi không còn bản ghi con nào.
--
-- Cột kết quả:
--   [Cay danh muc] : Tên thụt lề theo cấp (dễ đọc cấu trúc cây)
--   [Cap]          : Độ sâu (0 = gốc, 1 = con cấp 1, ...)
--   [Duong dan]    : Đường dẫn đầy đủ từ gốc đến nút hiện tại
--
-- =================================================================================
WITH CategoryTree AS (

    -- ── [1] ANCHOR: Danh mục gốc ─────────────────────────────────────────────────
    SELECT
        c.CategoryID,
        c.CategoryName,
        c.ParentID,
        0                                         AS CategoryLevel,
        CAST(c.CategoryName AS NVARCHAR(MAX))     AS Path,
        CAST(c.CategoryName AS NVARCHAR(MAX))     AS IndentedName
    FROM Categories c
    WHERE c.ParentID IS NULL

    UNION ALL

    -- ── [2] RECURSIVE: Tìm danh mục con ──────────────────────────────────────────
    SELECT
        c.CategoryID,
        c.CategoryName,
        c.ParentID,
        ct.CategoryLevel + 1,
        CAST(ct.Path + N' > ' + c.CategoryName          AS NVARCHAR(MAX)),
        CAST(REPLICATE(N'    ', ct.CategoryLevel + 1)
             + N'└─ ' + c.CategoryName                  AS NVARCHAR(MAX))
    FROM Categories c
    INNER JOIN CategoryTree ct ON c.ParentID = ct.CategoryID
)
SELECT
    CategoryID,
    IndentedName  AS [Cay danh muc],
    CategoryLevel AS [Cap],
    ParentID,
    Path          AS [Duong dan day du]
FROM CategoryTree
ORDER BY Path;
GO



USE FlashSaleDB;
GO

-- =================================================================================
-- PHẦN 1: sp_CheckoutFlashSale — LUỒNG CHỐT ĐƠN CHÍNH
-- =================================================================================
-- ResultCode:
--    0  = Thành công — đơn tạo, chờ thanh toán 15 phút
--   -1  = Sản phẩm không có trong Flash Sale này
--   -2  = Flash Sale chưa bắt đầu hoặc đã kết thúc
--   -3  = Hết suất (SoldQuantity >= TotalAllocated)
--   -4  = Không đủ tồn kho vật lý
--   -5  = User đã mua — vi phạm SaleLimit
--   -99 = Lỗi hệ thống
-- =================================================================================

IF OBJECT_ID('dbo.sp_CheckoutFlashSale', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_CheckoutFlashSale;
GO

CREATE PROCEDURE dbo.sp_CheckoutFlashSale
    @CustomerID  INT,
    @VariantID   INT,
    @EventID     INT,
    @OrderID     UNIQUEIDENTIFIER, -- [FIX]: Xóa chữ OUTPUT ở đây
    @ResultCode  INT              OUTPUT,
    @ResultMsg   NVARCHAR(500)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- [FIX]: Xóa dòng "SET @OrderID = NEWID();" ở đây vì C# đã cấp sẵn rồi
    SET @ResultCode = -99;
    SET @ResultMsg  = N'Loi he thong chua xac dinh.';

    DECLARE @FlashSaleItemID INT, @FlashSalePrice DECIMAL(18,2), @TotalAllocated INT;
    DECLARE @SoldQuantity INT, @SaleLimit INT, @EventStart DATETIME, @EventEnd DATETIME;
    DECLARE @StockQty INT, @ReservedQty INT, @ProductName NVARCHAR(200), @VariantName NVARCHAR(200);
    DECLARE @UserBoughtCount INT;

    -- ========================================================================
    -- FAIL-FAST: Kiểm tra SaleLimit TRƯỚC KHI mở Transaction (Dùng NOLOCK)
    -- ========================================================================
    SELECT @UserBoughtCount = COUNT(*)
    FROM Orders o WITH(NOLOCK)
    INNER JOIN OrderDetails od WITH(NOLOCK) ON od.OrderID = o.OrderID
    WHERE o.CustomerID = @CustomerID AND od.VariantID = @VariantID AND o.Status IN (0, 1);

    SELECT @SaleLimit = SaleLimit FROM FlashSaleItems WITH(NOLOCK) WHERE VariantID = @VariantID AND EventID = @EventID;

    IF @UserBoughtCount >= ISNULL(@SaleLimit, 1)
    BEGIN
        SET @ResultCode = -5;
        SET @ResultMsg  = N'Ban da tham gia mua san pham nay trong chuong trinh nay roi.';
        RETURN; -- Văng ra ngay, không tốn tài nguyên tạo Transaction
    END;

    -- Bắt đầu giao dịch với mức cô lập mặc định (READ COMMITTED)
    BEGIN TRY
        BEGIN TRANSACTION;

        -- ════════════════════════════════════════════════════════════════════════
        -- BƯỚC 1: KHÓA ROW FLASH SALE ITEM — Trái tim của cơ chế chống Oversell
        -- ════════════════════════════════════════════════════════════════════════
        SELECT
            @FlashSaleItemID = fsi.FlashSaleItemID,
            @FlashSalePrice  = fsi.FlashSalePrice,
            @TotalAllocated  = fsi.TotalAllocated,
            @SoldQuantity    = fsi.SoldQuantity,
            @SaleLimit       = fsi.SaleLimit,
            @EventStart      = fse.StartTime,
            @EventEnd        = fse.EndTime
        FROM FlashSaleItems fsi WITH (UPDLOCK, ROWLOCK)
        INNER JOIN FlashSaleEvents fse
            ON fse.EventID = fsi.EventID
        WHERE fsi.VariantID = @VariantID
          AND fsi.EventID   = @EventID;

        -- Kiểm tra: Item có tồn tại không?
        IF @FlashSaleItemID IS NULL
        BEGIN
            SET @ResultCode = -1;
            SET @ResultMsg  = N'San pham khong co trong chuong trinh Flash Sale nay.';
            ROLLBACK TRANSACTION; RETURN;
        END;

        -- Kiểm tra: Sự kiện có đang diễn ra không?
        IF GETDATE() NOT BETWEEN @EventStart AND @EventEnd
        BEGIN
            SET @ResultCode = -2;
            SET @ResultMsg  = N'Chuong trinh Flash Sale chua bat dau hoac da ket thuc.';
            ROLLBACK TRANSACTION; RETURN;
        END;

        -- Kiểm tra: Còn suất không?
        IF @SoldQuantity >= @TotalAllocated
        BEGIN
            SET @ResultCode = -3;
            SET @ResultMsg  = N'Rat tiec! Da het suat Flash Sale cho san pham nay.';
            ROLLBACK TRANSACTION; RETURN;
        END;

        -- ════════════════════════════════════════════════════════════════════════
        -- BƯỚC 2: Kiểm tra SaleLimit — mỗi user chỉ được mua 1 lần
        -- ════════════════════════════════════════════════════════════════════════
        

        -- ════════════════════════════════════════════════════════════════════════
        -- BƯỚC 3: KHÓA ROW INVENTORY — Chống oversell tồn kho vật lý
        -- ════════════════════════════════════════════════════════════════════════
        SELECT
            @StockQty    = i.StockQuantity,
            @ReservedQty = i.ReservedQuantity
        FROM Inventory i WITH (UPDLOCK, ROWLOCK)
        WHERE i.VariantID = @VariantID;

        -- Tồn kho khả dụng = Tổng kho - Đã giữ chỗ
        IF (@StockQty - @ReservedQty) < 1
        BEGIN
            SET @ResultCode = -4;
            SET @ResultMsg  = N'Khong du hang trong kho vat ly. Vui long thu lai sau.';
            ROLLBACK TRANSACTION; RETURN;
        END;

        -- ════════════════════════════════════════════════════════════════════════
        -- BƯỚC 4: Snapshot thông tin sản phẩm
        -- ════════════════════════════════════════════════════════════════════════
        SELECT
            @ProductName = p.ProductName,
            @VariantName = pv.VariantName
        FROM ProductVariants pv
        INNER JOIN Products p ON p.ProductID = pv.ProductID
        WHERE pv.VariantID = @VariantID;

        -- ════════════════════════════════════════════════════════════════════════
        -- BƯỚC 5: GHI DỮ LIỆU — Nguyên tắc ACID: All or Nothing
        -- ════════════════════════════════════════════════════════════════════════

        -- 5a. Tạo đơn hàng (Status = 0: Pending — chờ thanh toán 15 phút)
        INSERT INTO Orders (OrderID, CustomerID, TotalAmount, OrderDate, Status)
        VALUES (@OrderID, @CustomerID, @FlashSalePrice, GETDATE(), 0);

        -- 5b. Chi tiết đơn — snapshot tên + giá tại thời điểm mua
        INSERT INTO OrderDetails
            (OrderID, VariantID, ProductName, VariantName, Quantity, UnitPrice)
        VALUES (@OrderID, @VariantID, @ProductName, @VariantName, 1, @FlashSalePrice);

        -- 5c. Tăng SoldQuantity (an toàn: đã UPDLOCK ở Bước 1 → không race condition)
        UPDATE FlashSaleItems
        SET    SoldQuantity = SoldQuantity + 1
        WHERE  FlashSaleItemID = @FlashSaleItemID;

        -- 5d. Giữ chỗ kho vật lý 15 phút (an toàn: đã UPDLOCK ở Bước 3)
        UPDATE Inventory
        SET    ReservedQuantity = ReservedQuantity + 1,
               ReservedUntil   = DATEADD(MINUTE, 15, GETDATE())
        WHERE  VariantID = @VariantID;

        -- 5e. Ghi Saga log — bước Reserve
        INSERT INTO TransactionLogs (OrderID, Step, Status, CreatedAt)
        VALUES (@OrderID, N'Reserve', 1, GETDATE());

        -- COMMIT: Nhả tất cả U-lock → các transaction đang BLOCKED được tiếp tục
        COMMIT TRANSACTION;

        SET @ResultCode = 0;
        SET @ResultMsg  = N'Dat cho thanh cong! Vui long thanh toan trong 15 phut. OrderID: '
                        + CAST(@OrderID AS NVARCHAR(50));

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Ghi log lỗi trong transaction MỚI (transaction cũ đã rollback rồi)
        BEGIN TRY
            BEGIN TRANSACTION;
                INSERT INTO TransactionLogs (OrderID, Step, Status, CreatedAt)
                VALUES (@OrderID,
                        N'Reserve_ERR_' + CAST(ERROR_NUMBER() AS NVARCHAR(10)),
                        2, GETDATE());
            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        END CATCH;

        SET @ResultCode = -99;
        SET @ResultMsg  = N'Loi he thong ['  + CAST(ERROR_NUMBER() AS NVARCHAR(10))
                        + N']: '             + ERROR_MESSAGE()
                        + N' (dong '         + CAST(ERROR_LINE()   AS NVARCHAR(10)) + N')';
    END CATCH;

    
END;
GO

PRINT N'[OK] sp_CheckoutFlashSale da tao thanh cong.';
GO


-- =================================================================================
-- PHẦN 2: sp_ConfirmPayment — XÁC NHẬN THANH TOÁN
-- =================================================================================
-- ResultCode:
--    0  = Thanh toán thành công
--   -1  = Không tìm thấy OrderID
--   -2  = Đơn không ở trạng thái Pending (đã confirm hoặc đã hủy)
--   -99 = Lỗi hệ thống
-- =================================================================================

IF OBJECT_ID('dbo.sp_ConfirmPayment', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_ConfirmPayment;
GO

CREATE PROCEDURE dbo.sp_ConfirmPayment
    @OrderID       UNIQUEIDENTIFIER,
    @PaymentMethod NVARCHAR(50),    -- 'VNPay', 'Momo', 'ZaloPay'...
    @ResultCode    INT           OUTPUT,
    @ResultMsg     NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @Status    TINYINT;
        DECLARE @VariantID INT;
        DECLARE @Quantity  INT;
        DECLARE @Amount    DECIMAL(18,2);

        -- UPDLOCK: ngăn double-confirm khi 2 callback VNPay/Momo đến cùng lúc
        SELECT @Status = o.Status, @Amount = o.TotalAmount
        FROM Orders o WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
        WHERE o.OrderID = @OrderID;

        IF @Status IS NULL
        BEGIN
            SET @ResultCode = -1;
            SET @ResultMsg  = N'Khong tim thay don hang.';
            ROLLBACK TRANSACTION; RETURN;
        END;

        -- Chỉ xử lý khi đơn đang Pending (Status = 0)
        IF @Status <> 0
        BEGIN
            SET @ResultCode = -2;
            SET @ResultMsg  = N'Don hang khong o trang thai Pending. Trang thai hien tai: '
                            + CAST(@Status AS NVARCHAR(5));
            ROLLBACK TRANSACTION; RETURN;
        END;

        SELECT @VariantID = VariantID, @Quantity = Quantity
        FROM   OrderDetails WHERE OrderID = @OrderID;

        -- Chuyển đơn sang Success
        UPDATE Orders SET Status = 1 WHERE OrderID = @OrderID;

        -- Trừ tồn kho vật lý + giải phóng chỗ đã giữ
        UPDATE Inventory
        SET    StockQuantity    = StockQuantity    - @Quantity,
               ReservedQuantity = ReservedQuantity - @Quantity,
               ReservedUntil   = NULL
        WHERE  VariantID = @VariantID;

        -- Ghi nhận thanh toán
        INSERT INTO Payments (OrderID, Amount, PaymentMethod, Status, CreatedAt)
        VALUES (@OrderID, @Amount, @PaymentMethod, 1, GETDATE());

        -- Ghi Saga log — bước Payment
        INSERT INTO TransactionLogs (OrderID, Step, Status, CreatedAt)
        VALUES (@OrderID, N'Payment_' + @PaymentMethod, 1, GETDATE());

        COMMIT TRANSACTION;

        SET @ResultCode = 0;
        SET @ResultMsg  = N'Thanh toan thanh cong. Don hang da duoc xac nhan.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -99;
        SET @ResultMsg  = N'Loi he thong: ' + ERROR_MESSAGE();
    END CATCH;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
END;
GO

PRINT N'[OK] sp_ConfirmPayment da tao thanh cong.';
GO


-- =================================================================================
-- PHẦN 3: sp_CancelExpired — HOÀN KHO TỰ ĐỘNG
-- =================================================================================
-- ⚠️  TODO: Sau khi SP này chạy, Application layer PHẢI INCR Redis key
--     fs:stock:variant:{VariantID} cho mỗi đơn bị hủy
-- =================================================================================

IF OBJECT_ID('dbo.sp_CancelExpired', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_CancelExpired;
GO

CREATE PROCEDURE dbo.sp_CancelExpired
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    DECLARE @CancelCount INT = 0;

    BEGIN TRANSACTION;
    BEGIN TRY

        -- Bảng tạm lưu các đơn cần hủy
        DECLARE @Expired TABLE (
            OrderID   UNIQUEIDENTIFIER,
            VariantID INT,
            EventID   INT,
            Quantity  INT
        );

        -- Tìm đơn Pending quá 15 phút VÀ thời gian giữ kho đã hết
        INSERT INTO @Expired (OrderID, VariantID, EventID, Quantity)
        SELECT o.OrderID, od.VariantID, fsi.EventID, od.Quantity
        FROM Orders o
        INNER JOIN OrderDetails   od  ON od.OrderID   = o.OrderID
        INNER JOIN FlashSaleItems fsi ON fsi.VariantID = od.VariantID
        INNER JOIN Inventory      i   ON i.VariantID   = od.VariantID
        WHERE o.Status    = 0
          AND o.OrderDate < DATEADD(MINUTE, -15, GETDATE())
          AND i.ReservedUntil IS NOT NULL
          AND i.ReservedUntil < GETDATE();

        -- Hủy đơn
        UPDATE Orders SET Status = 2
        WHERE OrderID IN (SELECT OrderID FROM @Expired);

        -- Hoàn SoldQuantity → mở lại suất Flash Sale
        UPDATE fsi
        SET    fsi.SoldQuantity = fsi.SoldQuantity - e.Quantity
        FROM FlashSaleItems fsi
        INNER JOIN @Expired e ON e.EventID = fsi.EventID AND e.VariantID = fsi.VariantID;

        -- Hoàn ReservedQuantity → trả lại kho vật lý
        UPDATE i
        SET    i.ReservedQuantity = i.ReservedQuantity - e.Quantity,
               i.ReservedUntil   = NULL
        FROM Inventory i
        INNER JOIN @Expired e ON e.VariantID = i.VariantID;

        -- Ghi Saga log
        INSERT INTO TransactionLogs (OrderID, Step, Status, CreatedAt)
        SELECT OrderID, N'AutoCancel_Expired', 2, GETDATE() FROM @Expired; --Chuyển Orders.Status = 2 (Cancelled)

        SELECT @CancelCount = COUNT(*) FROM @Expired;
        COMMIT TRANSACTION;

        PRINT N'[AutoCancel] Da huy ' + CAST(@CancelCount AS NVARCHAR(10))
            + N' don hang het han. Suat Flash Sale da duoc hoan tra.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT N'Loi AutoCancel: ' + ERROR_MESSAGE();
    END CATCH;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
END;
GO

PRINT N'[OK] sp_CancelExpired da tao thanh cong.';
GO

-- =================================================================================
-- PHẦN 4: sp_UserCancel — NGƯỜI DÙNG CHỦ ĐỘNG HỦY
-- =================================================================================
CREATE OR ALTER PROCEDURE dbo.sp_UserCancel
    @OrderID UNIQUEIDENTIFIER,
    @CustomerID INT,
    @ResultCode INT OUTPUT,
    @ResultMsg NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @Status TINYINT, @VariantID INT, @Qty INT, @EventID INT, @EventEnd DATETIME;

        -- Dùng ROWLOCK để tối ưu
        SELECT @Status = Status FROM Orders WITH (UPDLOCK, HOLDLOCK, ROWLOCK) 
        WHERE OrderID = @OrderID AND CustomerID = @CustomerID;

        IF @Status IS NULL OR @Status <> 0 BEGIN
            SET @ResultCode = -1; SET @ResultMsg = N'Don hang khong the huy.';
            ROLLBACK TRANSACTION; RETURN;
        END

        -- Lấy thông tin order
        SELECT TOP 1 @VariantID = od.VariantID, @Qty = od.Quantity, @EventID = fsi.EventID
        FROM OrderDetails od WITH (ROWLOCK)
        INNER JOIN FlashSaleItems fsi ON fsi.VariantID = od.VariantID
        WHERE od.OrderID = @OrderID;

        IF @VariantID IS NULL OR @Qty IS NULL
        BEGIN
            SET @ResultCode = -2;
            SET @ResultMsg  = N'Khong tim thay chi tiet don hang.';
            ROLLBACK TRANSACTION; RETURN;
        END

        -- Lấy thời gian kết thúc event
        SELECT @EventEnd = EndTime 
        FROM FlashSaleEvents 
        WHERE EventID = @EventID;

        UPDATE Orders
        SET Status = 2
        WHERE OrderID = @OrderID;

        -- Chỉ hoàn slot nếu event còn chạy
        IF GETDATE() <= @EventEnd
        BEGIN
            UPDATE FlashSaleItems 
            SET SoldQuantity = SoldQuantity - @Qty 
            WHERE EventID = @EventID AND VariantID = @VariantID;
        END

        -- Hoàn kho vật lý
        UPDATE Inventory
        SET ReservedQuantity = ReservedQuantity - @Qty, ReservedUntil = NULL
        WHERE VariantID = @VariantID;

        -- Log
        INSERT INTO TransactionLogs (OrderID, Step, Status) VALUES (@OrderID, N'User_Cancel', 2);

        COMMIT TRANSACTION;
        SET @ResultCode = 0; SET @ResultMsg = N'Da huy don thanh cong.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -99; SET @ResultMsg = ERROR_MESSAGE();
    END CATCH;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
END;
GO

PRINT N'[OK] sp_UserCancel da tao thanh cong.';
GO

-- =================================================================================
-- PHẦN 5: sp_EventSummary — BÁO CÁO TỔNG KẾT EVENT
-- =================================================================================
-- Lấy thống kê toàn bộ một event: số đơn, doanh thu, hiệu suất lấp đầy
-- ResultCode:
--    0  = Thành công
--   -1  = Event không tồn tại
--   -99 = Lỗi hệ thống
-- =================================================================================

IF OBJECT_ID('dbo.sp_EventSummary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_EventSummary;
GO

CREATE PROCEDURE dbo.sp_EventSummary
    @EventID INT,
    @ResultCode INT OUTPUT,
    @ResultMsg NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ResultCode = -99;
    SET @ResultMsg = N'Loi he thong';

    BEGIN TRY
        -- Kiểm tra event tồn tại
        IF NOT EXISTS (SELECT 1 FROM FlashSaleEvents WHERE EventID = @EventID)
        BEGIN
            SET @ResultCode = -1;
            SET @ResultMsg = N'Event khong ton tai';
            RETURN;
        END

        -- Query tổng kết event
        SELECT
            e.EventID,
            e.Title                                     AS EventTitle,
            e.StartTime,
            e.EndTime,
            COUNT(DISTINCT o.OrderID)                  AS TongDonHang,
            SUM(CASE WHEN o.Status=1 THEN 1 END)       AS DonThanhCong,
            SUM(CASE WHEN o.Status=2 THEN 1 END)       AS DonHuy,
            SUM(CASE WHEN o.Status=0 THEN 1 END)       AS DonConPending,
            ISNULL(SUM(CASE WHEN o.Status=1 THEN o.TotalAmount END), 0) AS DoanhThuThucTe,
            -- Tỉ lệ chuyển đổi (%)
            CASE 
                WHEN COUNT(DISTINCT o.OrderID) = 0 THEN 0
                ELSE ROUND(100.0 * SUM(CASE WHEN o.Status=1 THEN 1 END) / COUNT(DISTINCT o.OrderID), 2)
            END AS TiLeChuyenDoi_Pct,
            -- Tổng suất đã phân bổ vs đã bán thực tế
            SUM(fsi.TotalAllocated)                     AS TongSuatPhanBo,
            SUM(fsi.SoldQuantity)                       AS TongSuatDaBan,
            -- Hiệu suất lấp đầy (%)
            CASE
                WHEN SUM(fsi.TotalAllocated) = 0 THEN 0
                ELSE ROUND(100.0 * SUM(fsi.SoldQuantity) / SUM(fsi.TotalAllocated), 2)
            END AS HieuSuatLapDay_Pct
        FROM FlashSaleEvents e
        LEFT JOIN FlashSaleItems fsi ON e.EventID = fsi.EventID
        LEFT JOIN OrderDetails od ON fsi.VariantID = od.VariantID
        LEFT JOIN Orders o ON od.OrderID = o.OrderID
        WHERE e.EventID = @EventID
        GROUP BY e.EventID, e.Title, e.StartTime, e.EndTime;

        SET @ResultCode = 0;
        SET @ResultMsg = N'Lay bao cao thanh cong';
    END TRY
    BEGIN CATCH
        SET @ResultCode = -99;
        SET @ResultMsg = ERROR_MESSAGE();
    END CATCH;
END;
GO

PRINT N'[OK] sp_EventSummary da tao thanh cong.';
GO

USE FlashSaleDB;
GO

-- =================================================================================
-- TUẦN 4.1: TRIGGER GUARD (CHỐNG ÂM KHO)
-- =================================================================================



-- =================================================================================
-- trg_Inventory_Guard — BẢO VỆ BẢNG INVENTORY
-- =================================================================================

IF OBJECT_ID('dbo.trg_Inventory_Guard', 'TR') IS NOT NULL
    DROP TRIGGER dbo.trg_Inventory_Guard;
GO

CREATE TRIGGER dbo.trg_Inventory_Guard
ON dbo.Inventory
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- ── [R1] Kiểm tra StockQuantity không âm ────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE StockQuantity < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R1: StockQuantity khong duoc am. Kiem tra lai nghiep vu tru kho.', 16, 1);
        RETURN;
    END;

    -- ── [R2] Kiểm tra ReservedQuantity không âm ─────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE ReservedQuantity < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R2: ReservedQuantity khong duoc am. Kiem tra lai nghiep vu hoan kho.', 16, 1);
        RETURN;
    END;

    -- ── [R3] Kiểm tra ReservedQuantity không vượt StockQuantity ─────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE ReservedQuantity > StockQuantity
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R3: ReservedQuantity (%d) vuot StockQuantity (%d). Khong the giu cho nhieu hon hang ton kho.',
            16, 1);
        RETURN;
    END;

    -- ── Log cảnh báo nếu tồn kho xuống thấp (< 10) ──────────────────────────────
    -- Không rollback, chỉ ghi nhận để DBA theo dõi
    IF EXISTS (
        SELECT 1
        FROM INSERTED i
        INNER JOIN DELETED d ON d.VariantID = i.VariantID
        WHERE i.StockQuantity < 10
          AND d.StockQuantity >= 10  -- Vừa xuống dưới ngưỡng 10
    )
    BEGIN
        -- Ghi log cảnh báo tồn kho thấp vào TransactionLogs
        INSERT INTO TransactionLogs (OrderID, Step, Status, CreatedAt)
        SELECT
            NULL,
            N'LOW_STOCK_WARNING | VariantID=' + CAST(i.VariantID AS NVARCHAR(10))
                + N' | Stock=' + CAST(i.StockQuantity AS NVARCHAR(10)),
            0,   -- 0 = Pending/Warning
            GETDATE()
        FROM INSERTED i
        INNER JOIN DELETED d ON d.VariantID = i.VariantID
        WHERE i.StockQuantity < 10
          AND d.StockQuantity >= 10;
    END;
END;
GO

PRINT N'[OK] trg_Inventory_Guard da tao thanh cong.';
GO


-- =================================================================================
-- trg_FlashSaleItems_Guard — BẢO VỆ BẢNG FLASHSALEITEMS
-- =================================================================================

IF OBJECT_ID('dbo.trg_FlashSaleItems_Guard', 'TR') IS NOT NULL
    DROP TRIGGER dbo.trg_FlashSaleItems_Guard;
GO

CREATE TRIGGER dbo.trg_FlashSaleItems_Guard
ON dbo.FlashSaleItems
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- ── [R4] SoldQuantity không âm ───────────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE SoldQuantity < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R4: SoldQuantity khong duoc am. Kiem tra lai nghiep vu hoan suat Flash Sale.', 16, 1);
        RETURN;
    END;

    -- ── [R5] SoldQuantity không vượt TotalAllocated — CHỐNG OVERSELL LỚP 3 ───────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE SoldQuantity > TotalAllocated
    )
    BEGIN
        -- Lấy thông tin chi tiết để báo lỗi rõ ràng
        DECLARE @VID_ERR   INT;
        DECLARE @SOLD_ERR  INT;
        DECLARE @TOTAL_ERR INT;

        SELECT TOP 1
            @VID_ERR   = VariantID,
            @SOLD_ERR  = SoldQuantity,
            @TOTAL_ERR = TotalAllocated
        FROM INSERTED
        WHERE SoldQuantity > TotalAllocated;

        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R5 — OVERSELL BI NGAN CHAN: VariantID=%d | SoldQuantity=%d > TotalAllocated=%d. Day la lop bao ve cuoi cung chong ban vuot han muc.',
            16, 1, @VID_ERR, @SOLD_ERR, @TOTAL_ERR);
        RETURN;
    END;

    -- ── [R6] TotalAllocated phải dương ───────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE TotalAllocated <= 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R6: TotalAllocated phai lon hon 0.', 16, 1);
        RETURN;
    END;

    -- ── [R7] FlashSalePrice không âm ─────────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE FlashSalePrice < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R7: FlashSalePrice khong duoc am.', 16, 1);
        RETURN;
    END;
END;
GO

PRINT N'[OK] trg_FlashSaleItems_Guard da tao thanh cong.';
GO


-- =================================================================================
-- trg_OrderDetails_Guard — BẢO VỆ BẢNG ORDERDETAILS
-- =================================================================================

IF OBJECT_ID('dbo.trg_OrderDetails_Guard', 'TR') IS NOT NULL
    DROP TRIGGER dbo.trg_OrderDetails_Guard;
GO

CREATE TRIGGER dbo.trg_OrderDetails_Guard
ON dbo.OrderDetails
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- ── [R8] Quantity phải dương ──────────────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE Quantity <= 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R8: Quantity phai lon hon 0.', 16, 1);
        RETURN;
    END;

    -- ── [R9] UnitPrice không âm ───────────────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED
        WHERE UnitPrice < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R9: UnitPrice khong duoc am.', 16, 1);
        RETURN;
    END;

    -- ── [R10] VariantID phải tồn tại ─────────────────────────────────────────────
    IF EXISTS (
        SELECT 1 FROM INSERTED i
        WHERE NOT EXISTS (
            SELECT 1 FROM ProductVariants pv
            WHERE pv.VariantID = i.VariantID
        )
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR(
            N'[TRG_GUARD] Vi pham R10: VariantID khong ton tai trong ProductVariants.', 16, 1);
        RETURN;
    END;
END;
GO

PRINT N'[OK] trg_OrderDetails_Guard da tao thanh cong.';
GO

USE FlashSaleDB;
GO

-- =================================================================================
-- TUẦN 4.2: WINDOW FUNCTIONS (PHÂN HỆ BÁO CÁO REAL-TIME)
-- =================================================================================

-- =================================================================================
-- BÁO CÁO 1 — TOP 5 SẢN PHẨM BÁN CHẠY NHẤT
-- =================================================================================

;WITH SalesSummary AS (
    SELECT
        fse.Title                                           AS TenSuKien,
        LEFT(p.ProductName, 40)                             AS TenSanPham,
        LEFT(pv.VariantName, 30)                            AS BienThe,
        c.CategoryName                                      AS DanhMuc,
        fsi.TotalAllocated                                  AS TongSuat,
        fsi.SoldQuantity                                    AS DaBan,
        fsi.TotalAllocated - fsi.SoldQuantity               AS ConLai,
        CAST(fsi.SoldQuantity * 100.0
             / NULLIF(fsi.TotalAllocated, 0) AS DECIMAL(5,1)) AS PhanTramBan,
        FORMAT(fsi.SoldQuantity * fsi.FlashSalePrice, 'N0') AS DoanhThu

    FROM FlashSaleItems  fsi
    INNER JOIN FlashSaleEvents  fse ON fse.EventID   = fsi.EventID
    INNER JOIN ProductVariants  pv  ON pv.VariantID  = fsi.VariantID
    INNER JOIN Products         p   ON p.ProductID   = pv.ProductID
    INNER JOIN Categories       c   ON c.CategoryID  = p.CategoryID
)
SELECT
    -- ── Xếp hạng ──────────────────────────────────────────────────────────────────
    RANK()       OVER (ORDER BY CAST(PhanTramBan AS FLOAT) DESC)   AS HangRank,
    DENSE_RANK() OVER (ORDER BY CAST(PhanTramBan AS FLOAT) DESC)   AS HangDenseRank,

    TenSuKien,
    TenSanPham,
    BienThe,
    DanhMuc,
    TongSuat,
    DaBan,
    ConLai,
    PhanTramBan,
    DoanhThu,

    -- ── Tổng suất đã bán trong toàn event (dùng SUM OVER để tính %) ─────────────
    SUM(DaBan)        OVER ()                                       AS TongDaBan_Event,
    CAST(DaBan * 100.0
         / NULLIF(SUM(DaBan) OVER (), 0) AS DECIMAL(5,1))          AS TiLeTrongEvent,

    -- ── Cờ FOMO: sản phẩm nào sắp hết (< 20% suất còn lại) ─────────────────────
    CASE
        WHEN CAST(PhanTramBan AS FLOAT) >= 80 THEN N'🔥 SAP HET — TAO FOMO'
        WHEN CAST(PhanTramBan AS FLOAT) >= 50 THEN N'⚡ BAN CHAY'
        ELSE N'  Binh thuong'
    END                                                             AS TrangThaiSale

FROM SalesSummary
ORDER BY CAST(PhanTramBan AS FLOAT) DESC
OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;
GO


-- =================================================================================
-- BÁO CÁO 2 — DOANH THU TÍCH LŨY THEO GIỜ (RUNNING TOTAL)
-- =================================================================================

;WITH HourlySales AS (
    -- Bước 1: Tổng hợp doanh thu theo từng giờ
    SELECT
        CAST(
            DATEADD(HOUR, DATEDIFF(HOUR, 0, o.OrderDate), 0)
        AS DATETIME)                                        AS GioSale,
        COUNT(DISTINCT o.OrderID)                           AS SoDon,
        SUM(od.UnitPrice * od.Quantity)                     AS DoanhThu
    FROM Orders      o
    INNER JOIN OrderDetails od ON od.OrderID = o.OrderID
    WHERE o.Status IN (0, 1)
    GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, o.OrderDate), 0)
),
WithLag AS (
    -- Bước 2: Tính LAG 1 lần duy nhất — dùng default NULL (không dùng 0 hay 1)
    --         NULL = không có dữ liệu giờ trước (giờ đầu tiên)
    --         0    = giờ trước có nhưng doanh thu = 0 (giờ ế)
    --         Phân biệt được 2 trường hợp này là mấu chốt của fix
    SELECT
        GioSale,
        SoDon,
        DoanhThu,
        LAG(DoanhThu) OVER (ORDER BY GioSale)               AS DoanhThu_GioTruoc
        -- Không đặt default → NULL khi không có hàng trước
        -- Sau này CASE sẽ xử lý NULL và 0 riêng biệt
    FROM HourlySales
)
SELECT
    FORMAT(GioSale, 'HH:mm dd/MM')                          AS Gio,
    SoDon,
    FORMAT(DoanhThu, 'N0')                                   AS DoanhThu_VND,

    -- ── Running Total: tổng tích lũy từ giờ đầu ──────────────────────────────
    FORMAT(
        SUM(DoanhThu) OVER (
            ORDER BY GioSale
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
    'N0')                                                    AS TichLuy_VND,

    -- ── Trung bình trượt 3 giờ ────────────────────────────────────────────────
    FORMAT(
        AVG(DoanhThu) OVER (
            ORDER BY GioSale
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
    'N0')                                                    AS TBTruot_3Gio,

    -- ── Doanh thu giờ liền trước ──────────────────────────────────────────────
    ISNULL(FORMAT(DoanhThu_GioTruoc, 'N0'), N'—')            AS GioTruoc_VND,

    -- ── % tăng trưởng — xử lý đầy đủ 3 trường hợp ───────────────────────────
    --   TH1: DoanhThu_GioTruoc IS NULL → giờ đầu tiên, chưa có baseline → '—'
    --   TH2: DoanhThu_GioTruoc = 0    → giờ ế rồi bất ngờ có đơn → 'Moi bat dau'
    --   TH3: DoanhThu_GioTruoc > 0    → tính % bình thường
    CASE
        WHEN DoanhThu_GioTruoc IS NULL
            THEN N'— (gio dau tien)'
        WHEN DoanhThu_GioTruoc = 0
            THEN N'New'
        ELSE
            CAST(
                CAST(
                    (DoanhThu - DoanhThu_GioTruoc) * 100.0
                    / NULLIF(DoanhThu_GioTruoc, 0)            -- DoanhThu_GioTruoc đã chắc chắn > 0
                AS DECIMAL(6,1))
            AS NVARCHAR(10)) + N'%'
    END                                                      AS TangTruong

FROM WithLag
ORDER BY GioSale;
GO


-- =================================================================================
-- BÁO CÁO 3 — TỐC ĐỘ BÁN HÀNG TỪNG SẢN PHẨM (LAG + LEAD)
-- =================================================================================

;WITH SaleCheckpoints AS (
    -- Tạo snapshot mỗi đơn hàng = 1 checkpoint theo thời gian
    SELECT
        od.VariantID,
        LEFT(p.ProductName, 35)                                        AS TenSanPham,
        o.OrderDate                                                    AS ThoiDiem,
        -- Đếm tích lũy số đơn tại mỗi thời điểm
        COUNT(o.OrderID) OVER (
            PARTITION BY od.VariantID
            ORDER BY o.OrderDate
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                              AS DonTichLuy,
        ROW_NUMBER() OVER (
            PARTITION BY od.VariantID
            ORDER BY o.OrderDate
        )                                                              AS STT
    FROM Orders      o
    INNER JOIN OrderDetails od ON od.OrderID  = o.OrderID
    INNER JOIN ProductVariants pv ON pv.VariantID = od.VariantID
    INNER JOIN Products        p  ON p.ProductID  = pv.ProductID
    WHERE o.Status IN (0, 1)
),
WithLagLead AS (
    SELECT
        VariantID,
        TenSanPham,
        ThoiDiem,
        DonTichLuy,
        STT,

        -- LAG: số đơn tích lũy tại checkpoint trước đó
        LAG(DonTichLuy, 1, 0)  OVER (PARTITION BY VariantID ORDER BY ThoiDiem) AS DonTichLuy_Truoc,

        -- LEAD: số đơn tích lũy tại checkpoint kế tiếp (dự báo chiều hướng)
        LEAD(ThoiDiem, 1)      OVER (PARTITION BY VariantID ORDER BY ThoiDiem) AS ThoiDiem_Tiep,

        -- Thời gian đặt đơn đầu tiên của sản phẩm này
        FIRST_VALUE(ThoiDiem)  OVER (PARTITION BY VariantID ORDER BY ThoiDiem
                                     ROWS UNBOUNDED PRECEDING)                  AS DonDauTien
    FROM SaleCheckpoints
)
SELECT
    TenSanPham,
    FORMAT(ThoiDiem, 'HH:mm:ss dd/MM')                                AS ThoiDiem,
    DonTichLuy                                                         AS TongDon,
    DonTichLuy - DonTichLuy_Truoc                                      AS DonMoiNhat,

    -- Thời gian giữa 2 đơn liên tiếp (phút)
    CASE
        WHEN ThoiDiem_Tiep IS NOT NULL
        THEN CAST(DATEDIFF(SECOND, ThoiDiem, ThoiDiem_Tiep) / 60.0 AS DECIMAL(6,1))
        ELSE NULL
    END                                                                AS PhutGiua2Don,

    -- Tốc độ trung bình từ đầu: số đơn / số phút
    CASE
        WHEN DATEDIFF(MINUTE, DonDauTien, ThoiDiem) > 0
        THEN CAST(DonTichLuy * 1.0
                  / DATEDIFF(MINUTE, DonDauTien, ThoiDiem) AS DECIMAL(6,2))
        ELSE NULL
    END                                                                AS DonPerPhut_TrungBinh

FROM WithLagLead
WHERE STT <= 5  -- Chỉ lấy 5 checkpoint đầu tiên mỗi sản phẩm
ORDER BY TenSanPham, ThoiDiem;
GO


-- =================================================================================
-- BÁO CÁO 4 — PHÂN TÍCH TỈ LỆ LẤP ĐẦY (PERCENT_RANK + CUME_DIST)
-- ─────────────────────────────────────────────────────────────────────────────────
-- Mục đích: So sánh mức độ "hot" của từng sản phẩm trong event.
--           Admin nhìn PERCENT_RANK biết ngay: sản phẩm này hot hơn bao nhiêu %
--           các sản phẩm khác trong cùng event.
-- =================================================================================

SELECT
    fse.Title                                                         AS TenSuKien,
    LEFT(p.ProductName, 35)                                           AS TenSanPham,
    c.CategoryName                                                    AS DanhMuc,
    fsi.TotalAllocated                                                AS TongSuat,
    fsi.SoldQuantity                                                  AS DaBan,
    CAST(fsi.SoldQuantity * 100.0
         / NULLIF(fsi.TotalAllocated, 0) AS DECIMAL(5,1))            AS PhanTramBan,

    -- ── Vị trí phần trăm: sản phẩm này hot hơn bao nhiêu % trong event ─────────
    CAST(
        PERCENT_RANK() OVER (
            PARTITION BY fsi.EventID
            ORDER BY fsi.SoldQuantity * 1.0 / NULLIF(fsi.TotalAllocated, 0)
        ) * 100 AS DECIMAL(5,1))                                     AS HotHonPercent,

    -- ── Cumulative Distribution: % sản phẩm có tỉ lệ bán <= sản phẩm này ───────
    CAST(
        CUME_DIST() OVER (
            PARTITION BY fsi.EventID
            ORDER BY fsi.SoldQuantity * 1.0 / NULLIF(fsi.TotalAllocated, 0)
        ) * 100 AS DECIMAL(5,1))                                     AS CumeDist_Percent,

    -- ── Nhãn xếp loại ────────────────────────────────────────────────────────────
    CASE
        WHEN PERCENT_RANK() OVER (
                PARTITION BY fsi.EventID
                ORDER BY fsi.SoldQuantity * 1.0 / NULLIF(fsi.TotalAllocated, 0)
             ) >= 0.8 THEN N'Top 20% — BEST SELLER'
        WHEN PERCENT_RANK() OVER (
                PARTITION BY fsi.EventID
                ORDER BY fsi.SoldQuantity * 1.0 / NULLIF(fsi.TotalAllocated, 0)
             ) >= 0.5 THEN N'Top 50% — KHA'
        ELSE N'Bottom 50% — CHAM'
    END                                                              AS XepLoai

FROM FlashSaleItems  fsi
INNER JOIN FlashSaleEvents fse ON fse.EventID  = fsi.EventID
INNER JOIN ProductVariants pv  ON pv.VariantID = fsi.VariantID
INNER JOIN Products        p   ON p.ProductID  = pv.ProductID
INNER JOIN Categories      c   ON c.CategoryID = p.CategoryID
ORDER BY fsi.EventID,
         fsi.SoldQuantity * 1.0 / NULLIF(fsi.TotalAllocated, 0) DESC;
GO


-- =================================================================================
-- BÁO CÁO 5 — PHÂN VỊ DOANH THU THEO DANH MỤC (NTILE)
-- =================================================================================

;WITH CategoryRevenue AS (
    SELECT
        c.CategoryName,
        SUM(od.UnitPrice * od.Quantity)    AS DoanhThu,
        COUNT(DISTINCT o.OrderID)          AS SoDon,
        COUNT(DISTINCT od.VariantID)       AS SoSanPham
    FROM Orders        o
    INNER JOIN OrderDetails    od ON od.OrderID   = o.OrderID
    INNER JOIN ProductVariants pv ON pv.VariantID = od.VariantID
    INNER JOIN Products        p  ON p.ProductID  = pv.ProductID
    INNER JOIN Categories      c  ON c.CategoryID = p.CategoryID
    WHERE o.Status IN (0, 1)
    GROUP BY c.CategoryName
)
SELECT
    CategoryName                                                        AS DanhMuc,
    FORMAT(DoanhThu, 'N0') + N' VND'                                    AS DoanhThu,
    SoDon                                                               AS SoDon,
    SoSanPham                                                           AS SoSanPham,

    -- ── Phân vị (Quartile): 1=thấp nhất, 4=cao nhất ──────────────────────────
    NTILE(4) OVER (ORDER BY DoanhThu)                                   AS Quartile,
    CASE NTILE(4) OVER (ORDER BY DoanhThu)
        WHEN 4 THEN N'Q4 — Ngoi sao (dau tu manh)'
        WHEN 3 THEN N'Q3 — Tiem nang (tang ngan sach)'
        WHEN 2 THEN N'Q2 — On dinh (giu nguyen)'
        WHEN 1 THEN N'Q1 — Yeu (xem xet loai bo)'
    END                                                                 AS ChienLuoc,

    -- ── % đóng góp vào tổng doanh thu ─────────────────────────────────────────
    CAST(DoanhThu * 100.0
         / NULLIF(SUM(DoanhThu) OVER (), 0) AS DECIMAL(5,1))           AS TiLeDongGop,

    -- ── Doanh thu tích lũy từ danh mục cao nhất xuống ─────────────────────────
    FORMAT(
        SUM(DoanhThu) OVER (ORDER BY DoanhThu DESC
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        'N0')                                                           AS TichLuyTuTop

FROM CategoryRevenue
ORDER BY DoanhThu DESC;
GO


-- =================================================================================
-- VIEW — vw_FlashSale_RealTimeDashboard
-- =================================================================================

IF OBJECT_ID('dbo.vw_FlashSale_RealTimeDashboard', 'V') IS NOT NULL
    DROP VIEW dbo.vw_FlashSale_RealTimeDashboard;
GO

CREATE VIEW dbo.vw_FlashSale_RealTimeDashboard
AS
WITH Base AS (
    SELECT
        fse.EventID,
        fse.Title                                                     AS TenSuKien,
        fse.StartTime,
        fse.EndTime,
        pv.VariantID,
        LEFT(p.ProductName, 40)                                       AS TenSanPham,
        c.CategoryName                                                AS DanhMuc,
        fsi.FlashSalePrice,
        fsi.TotalAllocated,
        fsi.SoldQuantity,
        fsi.TotalAllocated - fsi.SoldQuantity                         AS ConLai,
        CAST(fsi.SoldQuantity * 100.0
             / NULLIF(fsi.TotalAllocated, 0) AS DECIMAL(5,1))        AS PhanTramBan,
        fsi.SoldQuantity * fsi.FlashSalePrice                         AS DoanhThu
    FROM FlashSaleItems  fsi
    INNER JOIN FlashSaleEvents fse ON fse.EventID  = fsi.EventID
    INNER JOIN ProductVariants pv  ON pv.VariantID = fsi.VariantID
    INNER JOIN Products        p   ON p.ProductID  = pv.ProductID
    INNER JOIN Categories      c   ON c.CategoryID = p.CategoryID
    WHERE fse.EndTime > GETDATE()  -- Chỉ event đang chạy
)
SELECT
    EventID,
    TenSuKien,
    StartTime,
    EndTime,
    VariantID,
    TenSanPham,
    DanhMuc,
    FORMAT(FlashSalePrice, 'N0') + N' VND'                           AS GiaFlashSale,
    TotalAllocated,
    SoldQuantity,
    ConLai,
    PhanTramBan,
    FORMAT(DoanhThu, 'N0') + N' VND'                                 AS DoanhThu,

    -- ── Xếp hạng trong event (DENSE_RANK để không bỏ hạng) ──────────────────
    DENSE_RANK() OVER (
        PARTITION BY EventID
        ORDER BY PhanTramBan DESC
    )                                                                AS XepHangTrongEvent,

    -- ── % đóng góp doanh thu trong event ────────────────────────────────────
    CAST(DoanhThu * 100.0
         / NULLIF(SUM(DoanhThu) OVER (PARTITION BY EventID), 0)
         AS DECIMAL(5,1))                                            AS TiLeDT_TrongEvent,

    -- ── Nhãn trạng thái cho UI ───────────────────────────────────────────────
    CASE
        WHEN ConLai = 0            THEN N'HET HANG'
        WHEN PhanTramBan >= 80     THEN N'SAP HET'
        WHEN PhanTramBan >= 50     THEN N'BAN CHAY'
        ELSE                            N'CON HANG'
    END                                                              AS NhanTrangThai,

    
    -- ── Thời gian còn lại ───────────────────────────────────────────────
    CASE 
        WHEN GETDATE() < StartTime THEN DATEDIFF(MINUTE, StartTime, EndTime)
        WHEN GETDATE() > EndTime THEN 0
        ELSE DATEDIFF(MINUTE, GETDATE(), EndTime)
    END                                                              AS PhutConLai,

    -- ── Trạng thái event ───────────────────────────────────────────────
    CASE 
        WHEN GETDATE() < StartTime THEN N'SAP DIEN RA'
        WHEN GETDATE() BETWEEN StartTime AND EndTime THEN N'DANG DIEN RA'
        ELSE N'DA KET THUC'
    END                                                              AS TrangThaiEvent

FROM Base;
GO

PRINT N'[OK] vw_FlashSale_RealTimeDashboard da tao thanh cong.';
GO


-- =================================================================================
-- VIEW — vw_FlashSale_Leaderboard (Top 5 FOMO cho UI Admin)
-- =================================================================================

IF OBJECT_ID('dbo.vw_FlashSale_Leaderboard', 'V') IS NOT NULL
    DROP VIEW dbo.vw_FlashSale_Leaderboard;
GO

CREATE VIEW dbo.vw_FlashSale_Leaderboard
AS
WITH Ranked AS (
    SELECT
        fse.EventID,
        fse.Title                                                     AS TenSuKien,
        LEFT(p.ProductName, 40)                                       AS TenSanPham,
        c.CategoryName                                                AS DanhMuc,
        FORMAT(fsi.FlashSalePrice, 'N0') + N' VND'                   AS GiaFlashSale,
        fsi.SoldQuantity                                              AS DaBan,
        fsi.TotalAllocated                                            AS TongSuat,
        CAST(fsi.SoldQuantity * 100.0
             / NULLIF(fsi.TotalAllocated, 0) AS DECIMAL(5,1))        AS PhanTramBan,
        FORMAT(fsi.SoldQuantity * fsi.FlashSalePrice, 'N0') + N' VND' AS DoanhThu,

        -- Xếp hạng theo % bán trong từng event
        ROW_NUMBER() OVER (
            PARTITION BY fsi.EventID
            ORDER BY fsi.SoldQuantity * 1.0
                     / NULLIF(fsi.TotalAllocated, 0) DESC
        )                                                             AS Hang

    FROM FlashSaleItems  fsi
    INNER JOIN FlashSaleEvents fse ON fse.EventID  = fsi.EventID
    INNER JOIN ProductVariants pv  ON pv.VariantID = fsi.VariantID
    INNER JOIN Products        p   ON p.ProductID  = pv.ProductID
    INNER JOIN Categories      c   ON c.CategoryID = p.CategoryID
    WHERE fse.EndTime > GETDATE()
)
SELECT
    Hang,
    EventID,
    TenSuKien,
    TenSanPham,
    DanhMuc,
    GiaFlashSale,
    DaBan,
    TongSuat,
    PhanTramBan,
    DoanhThu,
    CASE
        WHEN Hang = 1 THEN N'🥇 HANG 1'
        WHEN Hang = 2 THEN N'🥈 HANG 2'
        WHEN Hang = 3 THEN N'🥉 HANG 3'
        ELSE               N'   HANG ' + CAST(Hang AS NVARCHAR(5))
    END                                                               AS HuyHieu
FROM Ranked
WHERE Hang <= 5;
GO

PRINT N'[OK] vw_FlashSale_Leaderboard da tao thanh cong.';
GO


-- =================================================================================
-- CHẠY VIEW
-- =================================================================================

PRINT N'--- Dashboard Real-time (TOP 10) ---';
SELECT TOP 10 * FROM dbo.vw_FlashSale_RealTimeDashboard
ORDER BY EventID, XepHangTrongEvent;


-- =================================================================================
-- STORED PROCEDURE — sp_GetRealtimeReport
-- =================================================================================

IF OBJECT_ID('dbo.sp_GetRealtimeReport', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_GetRealtimeReport;
GO

CREATE PROCEDURE dbo.sp_GetRealtimeReport
    @EventID INT = NULL   -- NULL = lấy tất cả event đang chạy
AS
BEGIN
    SET NOCOUNT ON;

    -- ── ResultSet 1: Leaderboard Top 5 (vw_FlashSale_Leaderboard) ───────────────
    SELECT *
    FROM dbo.vw_FlashSale_Leaderboard
    WHERE (@EventID IS NULL OR EventID = @EventID)
    ORDER BY EventID, Hang;

    -- ── ResultSet 2: Tổng quan event ────────────────────────────────────────────
    SELECT
        fse.EventID,
        fse.Title                                                     AS TenSuKien,
        DATEDIFF(MINUTE, GETDATE(), fse.EndTime)                      AS PhutConLai,
        COUNT(fsi.FlashSaleItemID)                                    AS TongSKU,
        SUM(fsi.TotalAllocated)                                       AS TongSuat,
        SUM(fsi.SoldQuantity)                                         AS TongDaBan,
        FORMAT(SUM(fsi.SoldQuantity * fsi.FlashSalePrice), 'N0')
            + N' VND'                                                 AS TongDoanhThu,
        CAST(SUM(fsi.SoldQuantity) * 100.0
             / NULLIF(SUM(fsi.TotalAllocated), 0) AS DECIMAL(5,1))   AS TiLeLapDay
    FROM FlashSaleEvents fse
    INNER JOIN FlashSaleItems fsi ON fsi.EventID = fse.EventID
    WHERE fse.EndTime > GETDATE()
      AND (@EventID IS NULL OR fse.EventID = @EventID)
    GROUP BY fse.EventID, fse.Title, fse.EndTime;

    -- ── ResultSet 3: Doanh thu theo danh mục (cho Pie Chart) ────────────────────
    SELECT
        c.CategoryName                                                AS DanhMuc,
        SUM(fsi.SoldQuantity * fsi.FlashSalePrice)                    AS DoanhThu,
        CAST(
            SUM(fsi.SoldQuantity * fsi.FlashSalePrice) * 100.0
            / NULLIF(SUM(SUM(fsi.SoldQuantity * fsi.FlashSalePrice))
                     OVER (), 0)
            AS DECIMAL(5,1))                                          AS TiLe
    FROM FlashSaleItems  fsi
    INNER JOIN FlashSaleEvents  fse ON fse.EventID  = fsi.EventID
    INNER JOIN ProductVariants  pv  ON pv.VariantID = fsi.VariantID
    INNER JOIN Products         p   ON p.ProductID  = pv.ProductID
    INNER JOIN Categories       c   ON c.CategoryID = p.CategoryID
    WHERE fse.EndTime > GETDATE()
      AND (@EventID IS NULL OR fse.EventID = @EventID)
    GROUP BY c.CategoryName
    ORDER BY DoanhThu DESC;
END;
GO

PRINT N'[OK] sp_GetRealtimeReport da tao thanh cong.';
GO

-- Chạy thử SP
PRINT N'';
PRINT N'--- Chay sp_GetRealtimeReport (EventID = NULL = tat ca event) ---';
EXEC dbo.sp_GetRealtimeReport @EventID = NULL;
GO