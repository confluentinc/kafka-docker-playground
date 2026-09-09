FROM python:3

ADD consumer.py /

RUN OPENSSL_ia32cap=0x0 pip install pika

CMD sleep infinity