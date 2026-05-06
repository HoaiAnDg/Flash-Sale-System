using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using RabbitMQ.Client;

namespace FlashSaleMarketplace.Api.Messaging
{
    public class RabbitMqProducer : IDisposable
    {
        private readonly IConnection _connection;
        // Rổ chứa các kênh (Channel Pool)
        private readonly ConcurrentBag<IModel> _channelPool = new();

        public RabbitMqProducer()
        {
            var factory = new ConnectionFactory { HostName = "localhost" };
            _connection = factory.CreateConnection();
        }

        public void PublishMessage(string queueName, object message)
        {
            var json = JsonSerializer.Serialize(message);
            var body = Encoding.UTF8.GetBytes(json);

            // Lấy 1 ống từ trong rổ ra (Nếu rổ trống thì tạo ống mới)
            if (!_channelPool.TryTake(out var channel))
            {
                channel = _connection.CreateModel();
                channel.QueueDeclare(queue: queueName, durable: true, exclusive: false, autoDelete: false, arguments: null);
            }

            var properties = channel.CreateBasicProperties();
            properties.Persistent = true;

            // Bắn tin nhắn tốc độ cao (Không bị lock)
            channel.BasicPublish(exchange: "", routingKey: queueName, basicProperties: properties, body: body);

            // Bắn xong thì quăng ống lại vào rổ cho người khác xài
            _channelPool.Add(channel);
        }

        public void Dispose()
        {
            foreach (var channel in _channelPool) channel?.Dispose();
            _connection?.Dispose();
        }
    }
}