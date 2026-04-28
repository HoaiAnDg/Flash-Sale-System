# HỆ THỐNG FLASH SALE MARKETPLACE (ENTERPRISE ARCHITECTURE)

Dự án mô phỏng hệ thống thương mại điện tử chịu tải cao (High-Concurrency) trong sự kiện Flash Sale, áp dụng kiến trúc Phân tán (Distributed System) và Bất đồng bộ (Asynchronous Messaging).

## 🛠 YÊU CẦU HỆ THỐNG (PREREQUISITES)
- Docker Desktop & WSL2 (Đã bật cấu hình WSL integration).
- .NET 8.0 SDK.
- SQL Server (Local hoặc Container).
- Apache JMeter (Dùng để Stress Test).
- Trình duyệt Web (Chrome/Edge).

---

## 🚀 QUY TRÌNH KHỞI ĐỘNG VÀ KIỂM THỬ HỆ THỐNG

### BƯỚC 1: Khởi động Hạ tầng Container (Infrastructure)
Hệ thống sử dụng Docker để cô lập môi trường cho Redis, RabbitMQ và MongoDB.
1. Mở Terminal tại thư mục gốc của dự án.
2. Chạy lệnh: `docker compose up -d`
3. Chờ khoảng 10 giây để các container khởi động. Kiểm tra trạng thái bằng lệnh `docker ps`.

### BƯỚC 2: Chuẩn bị Cơ sở dữ liệu (SQL Server)
1. Mở SQL Server Management Studio (SSMS) hoặc Azure Data Studio.
2. Kết nối vào Database `FlashSaleDB`.
3. Mở và thực thi (Execute) script `database/5_SpikeTest_Reset_Scenario.sql`.
   *(Mục đích: Xóa dữ liệu rác cũ, reset lại đúng 5 sản phẩm HOT với số lượng 1000 suất/sản phẩm).*

### BƯỚC 3: Khởi động Backend API (.NET 8)
1. Mở Terminal tại thư mục `FlashSaleMarketplace.Api`.
2. Chạy lệnh: `dotnet run`
3. Đảm bảo Terminal báo: `Now listening on: http://localhost:5049` (Không có lỗi đỏ).
4. Lúc này, Background Worker đã tự động kết nối với RabbitMQ và túc trực xử lý Hàng đợi.

### BƯỚC 4: Mồi dữ liệu lên RAM (Pre-load Cache)
Thay vì để hệ thống chọc thẳng xuống SQL Server, ta sẽ nạp kho hàng lên Redis trước giờ G.
1. Mở trình duyệt, truy cập: `http://localhost:5049/swagger`
2. Tìm API `POST /api/checkout/preload-redis` và nhấn **Execute** (Hoặc dùng Postman gọi POST).
3. Đảm bảo kết quả trả về: `"Khởi tạo Kho hàng trên Redis (RAM) thành công!"`.

### BƯỚC 5: Giám sát Hệ thống (Monitoring)
Mở sẵn 2 tab trình duyệt để quan sát hệ thống xử lý theo thời gian thực:
- **Admin Dashboard:** `http://localhost:5049/admin.html` (Xem tiến trình chốt đơn).
- **RabbitMQ Dashboard:** `http://localhost:15672` (User/Pass: `guest`/`guest` -> Chuyển sang tab **Queues** để xem tốc độ hút tin nhắn).

---

## 🎯 KỊCH BẢN KIỂM THỬ CHỊU TẢI (STRESS TEST) VỚI JMETER

Hệ thống có cấu hình "Khiên chắn" Rate Limiting giới hạn 5 requests/giây/IP để chống Bot/DDoS.

### Kịch bản 1: Kiểm thử Tính năng Chống Spam (Rate Limiting)
Mô phỏng 1 Hacker dùng 1 địa chỉ IP nã 150.000 requests.
1. Mở file cấu hình JMeter (`View Results Tree.jmx`).
2. Vào **Thread Group** -> Chỉnh số lượng Threads: `150000`.
3. Nhấn **Play**.
4. **Kết quả kỳ vọng:** Hệ thống đá văng gần như toàn bộ request với mã lỗi HTTP `429 (Too Many Requests)`. Database an toàn, Dashboard chỉ nhảy vài đơn vị.

### Kịch bản 2: Kiểm thử Năng lực xử lý thực tế (Enterprise Mode)
Mô phỏng 150.000 Khách hàng thật từ 150.000 địa chỉ IP khác nhau.
1. Tắt JMeter, làm lại **Bước 2** và **Bước 4** để reset lại kho hàng.
2. Mở JMeter, chuột phải vào Thread Group -> Add -> Config Element -> **HTTP Header Manager**.
3. Thêm cấu hình giả lập IP động:
   - Name: `X-Real-IP`
   - Value: `${__Random(1,255)}.${__Random(1,255)}.${__Random(1,255)}.${__Random(1,255)}`
4. Nhấn **Play** để bắn 150.000 requests.
5. **Kết quả kỳ vọng:** - Lớp Rate Limit cho phép toàn bộ requests lọt qua.
   - Redis Lua Script tiếp nhận và trừ số lượng trên RAM siêu tốc (< 10ms), thông lượng (Throughput) đạt ~10.000 req/s.
   - 5.000 người mua thành công được đưa vào Hàng đợi RabbitMQ. 145.000 người đến trễ nhận thông báo "Hết hàng" mã lỗi `400`.
   - Chuyển sang Web RabbitMQ: Thấy hàng đợi `order_queue` đang có 5000 tin nhắn và giảm dần.
   - Chuyển sang Terminal C#: Worker in ra log `[DATA SYNC]` cho thấy MongoDB đang đồng bộ xóa giỏ hàng.
   - Chuyển sang Web Admin Dashboard: Tiến trình chốt đơn tịnh tiến mượt mà từ 0 đến mức hoàn hảo 1000/1000 suất cho cả 5 sản phẩm.