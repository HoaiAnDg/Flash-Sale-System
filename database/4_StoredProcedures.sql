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
    @OrderID     UNIQUEIDENTIFIER OUTPUT,
    @ResultCode  INT              OUTPUT,
    @ResultMsg   NVARCHAR(500)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Khởi tạo output
    SET @OrderID    = NEWID();
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