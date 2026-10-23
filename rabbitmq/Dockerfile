# Erweitert das offizielle RabbitMQ-Image um das STOMP-Plugin. STOMP ist ein
# einfaches, textbasiertes Protokoll - damit kann der Delphi-Task-Service
# Events publizieren, ohne eine komplette AMQP-0-9-1-Client-Library zu
# brauchen (fuer die es in Delphi keine offizielle gibt). Der Python-Service
# konsumiert ganz normal per AMQP (pika) - beide Protokolle landen im selben
# Exchange, RabbitMQ vermittelt dazwischen.
#
# Dazu wird die Topologie (Exchange "task-events", durable Queue des
# History-Service, Binding) als Code mitgeliefert (definitions.json).
FROM rabbitmq:3-management-alpine
RUN rabbitmq-plugins enable --offline rabbitmq_stomp
COPY definitions.json /etc/rabbitmq/definitions.json
COPY 20-definitions.conf /etc/rabbitmq/conf.d/20-definitions.conf
