<?php

define("HOST",     getenv("TEST_RABBITMQ_HOST") ? getenv("TEST_RABBITMQ_HOST") : "localhost");
define("PORT",     getenv("TEST_RABBITMQ_PORT") ? getenv("TEST_RABBITMQ_PORT") : "5672");
define("USER",     getenv("TEST_RABBITMQ_USER") ? getenv("TEST_RABBITMQ_USER") : "guest");
define("PASS",     getenv("TEST_RABBITMQ_PASS") ? getenv("TEST_RABBITMQ_PASS") : "guest");
define("ATTEMPTS", getenv("TEST_ATTEMPTS")      ? getenv("TEST_ATTEMPTS")      : 10);

$connection = new AMQPConnection();
$connection->setHost(HOST);
$connection->setPort(PORT);
$connection->setLogin(USER);
$connection->setPassword(PASS);
$connection->connect();

$channel = new AMQPChannel($connection);

$exchange_name = "test-ex";
$exchange = new AMQPExchange($channel);
$exchange->setType(AMQP_EX_TYPE_FANOUT);
$exchange->setName($exchange_name);
$exchange->declareExchange();

$queue = new AMQPQueue($channel);
$queue->setName("test-q");
$queue->declareQueue();
$queue->bind($exchange_name,$queue->getName());

$i = 1;
$exit_code = 1; // exception should be raised if the test setup works correctly

while ($i <= ATTEMPTS) {
    echo "Getting messages, attempt #", $i, PHP_EOL;
    try {
        $queue->get(AMQP_AUTOACK);
        sleep(1);
    } catch(Exception $e) {
        $exit_code = 0;
        echo "Caught exception: ", get_class($e), ": ",  $e->getMessage(), PHP_EOL;
        break;
    }
    $i++;
}

if($exit_code == 1) {
    echo "FAIL! Exception should be raised when the test setup works correctly", PHP_EOL;
} else {
    echo "SUCCESS! Exception was raised.", PHP_EOL;
}
echo "Exiting with exit code: ", $exit_code, PHP_EOL;
exit($exit_code);
