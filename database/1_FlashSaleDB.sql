USE master;
GO

-- =========================================
-- 0. XÓA DATABASE CŨ (NẾU CÓ) ĐỂ TẠO MỚI CLEAN 100%
-- =========================================
IF EXISTS (SELECT name FROM sys.databases WHERE name = N'FlashSaleDB')
BEGIN
    PRINT N'Dang xoa FlashSaleDB cu...';
    -- Ép đóng tất cả các kết nối đang mở để tránh lỗi "Database is in use"
    ALTER DATABASE FlashSaleDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FlashSaleDB;
END
GO

-- Tạo database mới
CREATE DATABASE FlashSaleDB;
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