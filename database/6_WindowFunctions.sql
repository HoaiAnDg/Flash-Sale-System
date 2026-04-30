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