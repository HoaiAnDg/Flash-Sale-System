using System.Text;
using System.Text.Json;
using RabbitMQ.Client;

namespace FlashSaleMarketplace.Api.Messaging
{
    public class RabbitMqProducer : IDisposable
    {
        private readonly IConnection _connection;
        private readonly IModel _channel;
        private readonly object _lock = new object(); // ĐÈN GIAO THÔNG

        public RabbitMqProducer()
        {
            var factory = new ConnectionFactory { HostName = "localhost" };
            _connection = factory.CreateConnection();
            
            // TẠO ĐÚNG 1 KÊNH DUY NHẤT LÚC KHỞI ĐỘNG
            _channel = _connection.CreateModel();
            _channel.QueueDeclare(queue: "order_queue", durable: true, exclusive: false, autoDelete: false, arguments: null);
        }

        public void PublishMessage(string queueName, object message)
        {
            var json = JsonSerializer.Serialize(message);
            var body = Encoding.UTF8.GetBytes(json);

            var properties = _channel.CreateBasicProperties();
            properties.Persistent = true;

            // DÙNG LOCK: Tại 1 mili-giây, chỉ 1 request được phép ném tin nhắn vào ống.
            // Ngăn chặn xung đột đa luồng tuyệt đối mà không cần mở ống mới!
            lock (_lock)
            {
                _channel.BasicPublish(exchange: "", routingKey: queueName, basicProperties: properties, body: body);
            }
        }

        public void Dispose()
        {
            _channel?.Dispose();
            _connection?.Dispose();
        }
    }
}