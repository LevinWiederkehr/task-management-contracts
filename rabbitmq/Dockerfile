# Erweitert das offizielle RabbitMQ-Image um das STOMP-Plugin. STOMP ist ein
# einfaches, textbasiertes Protokoll - damit kann der Delphi-Task-Service
# Events publizieren, ohne eine komplette AMQP-0-9-1-Client-Library zu
# brauchen (fuer die es in Delphi keine offizielle gibt). Der Python-Service
# konsumiert ganz normal per AMQP (pika) - beide Protokolle landen im selben
# Exchange, RabbitMQ vermittelt dazwischen.
FROM rabbitmq:3-management-alpine
RUN rabbitmq-plugins enable --offline rabbitmq_stomp
