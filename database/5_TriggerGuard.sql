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