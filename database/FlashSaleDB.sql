-- 1. Tạo Database
CREATE DATABASE FlashSaleDB;
GO
USE FlashSaleDB;
GO

-- 2. Bảng Danh mục (Categories)
CREATE TABLE Categories (
    CategoryID INT PRIMARY KEY IDENTITY(1,1),
    CategoryName NVARCHAR(100) NOT NULL,
    ParentID INT NULL, -- Hỗ trợ đệ quy CTE cho Tuần 2
    CONSTRAINT FK_Category_Parent FOREIGN KEY (ParentID) REFERENCES Categories(CategoryID)
);

-- 3. Bảng Sản phẩm (Products)
CREATE TABLE Products (
    ProductID INT PRIMARY KEY IDENTITY(1,1),
    ProductName NVARCHAR(200) NOT NULL,
    Description NVARCHAR(MAX),
    BasePrice DECIMAL(18, 2) NOT NULL,
    CategoryID INT,
    CreatedAt DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Product_Category FOREIGN KEY (CategoryID) REFERENCES Categories(CategoryID),
    CONSTRAINT CHK_BasePrice_Positive CHECK (BasePrice >= 0)
);

-- 4. Bảng Kho hàng (Inventory) - Cực kỳ quan trọng cho Flash Sale
CREATE TABLE Inventory (
    InventoryID INT PRIMARY KEY IDENTITY(1,1),
    ProductID INT UNIQUE NOT NULL, -- Mỗi sản phẩm có 1 dòng kho
    StockQuantity INT NOT NULL DEFAULT 0,
    ReservedQuantity INT NOT NULL DEFAULT 0, -- Lượng hàng đang chờ thanh toán
    Version ROWVERSION, -- Hỗ trợ Optimistic Concurrency cho các tuần sau
    CONSTRAINT FK_Inventory_Product FOREIGN KEY (ProductID) REFERENCES Products(ProductID),
    CONSTRAINT CHK_Stock_Positive CHECK (StockQuantity >= 0),
    CONSTRAINT CHK_Inventory_Reserved_Positive CHECK (ReservedQuantity >= 0),-- Chống âm kho
    CONSTRAINT CHK_Stock_Logic CHECK (StockQuantity >= ReservedQuantity) -- Không cho giữ chỗ quá số lượng có sẵn
);

-- 5. Bảng Đơn hàng (Orders)
CREATE TABLE Orders (
    OrderID UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(), -- Dùng GUID để tránh đoán ID đơn hàng
    CustomerID INT NOT NULL,
    TotalAmount DECIMAL(18, 2),
    OrderDate DATETIME DEFAULT GETDATE(),
    Status TINYINT DEFAULT 0 -- 0: Pending, 1: Success, 2: Cancelled
);

-- Tạo Index cho ProductID trong Inventory để truy vấn tồn kho cực nhanh
CREATE INDEX IX_Inventory_ProductID ON Inventory(ProductID);