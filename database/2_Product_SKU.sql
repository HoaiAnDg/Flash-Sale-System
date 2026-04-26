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