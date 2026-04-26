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
            _channel.BasicQos(prefetchSize: 0, prefetchCount: 1, global: false);
            
            var consumer = new EventingBasicConsumer(_channel);
            
            consumer.Received += async (model, ea) =>
            {
                var body = ea.Body.ToArray();
                var message = Encoding.UTF8.GetString(body);
                var orderData = JsonSerializer.Deserialize<OrderMessage>(message);

                if (orderData != null)
                {
                    await ProcessOrderInSqlAndMongo(orderData);
                }

                _channel.BasicAck(deliveryTag: ea.DeliveryTag, multiple: false);
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
            parameters.Add("@OrderID", dbType: DbType.Guid, direction: ParameterDirection.Output);
            parameters.Add("@ResultCode", dbType: DbType.Int32, direction: ParameterDirection.Output);
            parameters.Add("@ResultMsg", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

            try {
                // 1. CHỐT ĐƠN VÀO SQL
                await connection.ExecuteAsync("sp_CheckoutFlashSale", parameters, commandType: CommandType.StoredProcedure);
                
                // Delay nhỏ giúp Dashboard tăng số mượt mà như Shopee thật
                await Task.Delay(20); 
                
                int resultCode = parameters.Get<int>("@ResultCode");
                string resultMsg = parameters.Get<string>("@ResultMsg");
                
                if(resultCode == 0) {
                    // 2. DATA SYNC: NẾU SQL THÀNH CÔNG -> GỌI MONGO XÓA GIỎ HÀNG
                    using var scope = _serviceProvider.CreateScope();
                    var mongoDb = scope.ServiceProvider.GetRequiredService<IMongoDatabase>();
                    var cartCollection = mongoDb.GetCollection<Cart>("Carts");

                    // Chọc vào Mongo, rút cái Item đã mua ra khỏi mảng Items
                    var filter = Builders<Cart>.Filter.Eq(c => c.UserId, orderData.UserId);
                    var update = Builders<Cart>.Update.PullFilter(c => c.Items, i => i.VariantId == orderData.VariantId);
                    await cartCollection.UpdateOneAsync(filter, update);

                    // In log Xanh Lơ ra màn hình Console để ngắm
                    Console.ForegroundColor = ConsoleColor.Cyan;
                    Console.WriteLine($"[DATA SYNC] Đã xóa Variant {orderData.VariantId} khỏi Giỏ hàng Mongo của User {orderData.UserId}");
                    Console.ResetColor();
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
        public int UserId { get; set; }
        public int VariantId { get; set; }
        public int EventId { get; set; }
    }
}