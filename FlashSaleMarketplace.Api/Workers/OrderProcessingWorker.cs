using System.Data;
using System.Text;
using System.Text.Json;
using Dapper;
using FlashSaleMarketplace.Api.Models; // Dùng để gọi model Cart
using Microsoft.Data.SqlClient;
using MongoDB.Driver;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace FlashSaleMarketplace.Api.Workers
{
    public class OrderProcessingWorker : BackgroundService
    {
        private readonly string _sqlConnectionString;
        private readonly IServiceProvider _serviceProvider; // Dùng để tiêm MongoDB vào Background
        private IConnection _rabbitConnection;
        private IModel _channel;

        public OrderProcessingWorker(IConfiguration config, IServiceProvider serviceProvider)
        {
            _sqlConnectionString = config.GetConnectionString("SqlServerConnection") ?? "";
            _serviceProvider = serviceProvider;
            
            var factory = new ConnectionFactory { HostName = "localhost" };
            _rabbitConnection = factory.CreateConnection();
            _channel = _rabbitConnection.CreateModel();
            _channel.QueueDeclare(queue: "order_queue", durable: true, exclusive: false, autoDelete: false, arguments: null);
        }

        protected override Task ExecuteAsync(CancellationToken stoppingToken)
        {
            // 1. TĂNG PREFETCH: Cho phép Worker lấy một lúc 200 tin nhắn từ Queue
            _channel.BasicQos(prefetchSize: 0, prefetchCount: 200, global: false);
            
            var consumer = new EventingBasicConsumer(_channel);
            
            consumer.Received += (model, ea) =>
            {
                var body = ea.Body.ToArray();
                var message = Encoding.UTF8.GetString(body);
                var orderData = JsonSerializer.Deserialize<OrderMessage>(message);

                if (orderData != null)
                {
                    // 2. CHẠY ĐA LUỒNG: Không chờ SQL insert xong mới nhận đơn tiếp theo
                    _ = Task.Run(async () => 
                    {
                        await ProcessOrderInSqlAndMongo(orderData);
                        // 3. Báo cáo hoàn thành rải rác
                        _channel.BasicAck(deliveryTag: ea.DeliveryTag, multiple: false);
                    });
                }
            };

            _channel.BasicConsume(queue: "order_queue", autoAck: false, consumer: consumer);
            return Task.CompletedTask;
        }

        private async Task ProcessOrderInSqlAndMongo(OrderMessage orderData)
        {
            using var connection = new SqlConnection(_sqlConnectionString);
            var parameters = new DynamicParameters();
            parameters.Add("@CustomerID", orderData.UserId);
            parameters.Add("@VariantID", orderData.VariantId);
            parameters.Add("@EventID", orderData.EventId);
            
            // [FIX]: Truyền cứng OrderID do API cấp, KHÔNG dùng kiểu Output nữa
            parameters.Add("@OrderID", orderData.OrderId); 
            
            parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
            parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

            try {
                // CHỐT ĐƠN VÀO SQL
                await connection.ExecuteAsync("sp_CheckoutFlashSale", parameters, commandType: CommandType.StoredProcedure);
                
                int resultCode = parameters.Get<int>("@ResultCode");
                string resultMsg = parameters.Get<string>("@ResultMsg");

                Console.ForegroundColor = ConsoleColor.Magenta;
                Console.WriteLine($"[WORKER SQL] Chốt đơn {orderData.OrderId} | Kết quả: {resultCode} | Thông báo: {resultMsg}");
                Console.ResetColor();
                
                if(resultCode == 0) {
                    // ==============================================================
                    // TÍNH NĂNG HOÀN HẢO: DATA SYNC VỚI RETRY PATTERN
                    // ==============================================================
                    using var scope = _serviceProvider.CreateScope();
                    var mongoDb = scope.ServiceProvider.GetRequiredService<IMongoDatabase>();
                    var cartCollection = mongoDb.GetCollection<Cart>("Carts");

                    var filter = Builders<Cart>.Filter.Eq(c => c.UserId, orderData.UserId);
                    var update = Builders<Cart>.Update.PullFilter(c => c.Items, i => i.VariantId == orderData.VariantId);

                    int maxRetries = 3;
                    bool syncSuccess = false;

                    for (int retry = 1; retry <= maxRetries; retry++)
                    {
                        try
                        {
                            await cartCollection.UpdateOneAsync(filter, update);
                            syncSuccess = true;
                            
                            Console.ForegroundColor = ConsoleColor.Cyan;
                            Console.WriteLine($"[DATA SYNC] Đã xóa Variant {orderData.VariantId} khỏi Mongo của User {orderData.UserId}");
                            Console.ResetColor();
                            break; // Thành công thì thoát vòng lặp ngay
                        }
                        catch (Exception mongoEx)
                        {
                            Console.ForegroundColor = ConsoleColor.DarkYellow;
                            Console.WriteLine($"[CẢNH BÁO] Đồng bộ Mongo thất bại lần {retry}. Thử lại sau 50ms... Lỗi: {mongoEx.Message}");
                            Console.ResetColor();
                            int retryDelay = (int)Math.Pow(2, retry) * 50; 
                            await Task.Delay(retryDelay);
                        }
                    }

                    // Cơ chế Fallback (Báo cáo Admin) nếu thử 3 lần vẫn thất bại
                    if (!syncSuccess)
                    {
                        Console.ForegroundColor = ConsoleColor.DarkRed;
                        Console.WriteLine($"[CẢNH BÁO NGHIÊM TRỌNG] User {orderData.UserId} đã chốt đơn nhưng KHÔNG THỂ xóa giỏ hàng Mongo!");
                        Console.ResetColor();
                        // Ở hệ thống thực tế, ta sẽ Insert lỗi này vào 1 bảng SQL tên là "Sync_Errors" để Admin xử lý tay sau.
                    }
                } else {
                    Console.ForegroundColor = ConsoleColor.Yellow;
                    Console.WriteLine($"[SQL TỪ CHỐI]: {resultMsg}");
                    Console.ResetColor();
                }
            } catch (Exception ex) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine($"[LỖI WORKER SQL NGHIÊM TRỌNG]: {ex.Message}");
                Console.ResetColor();
            }
        }
    }

    public class OrderMessage
    {
        public Guid OrderId { get; set; } 
        public int UserId { get; set; }
        public int VariantId { get; set; }
        public int EventId { get; set; }
    }
}