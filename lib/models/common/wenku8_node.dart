enum Wenku8Node {
  wwwWenku8Net,
  wwwWenku8Cc,
  proxyWorker;

  String get label => ["wenku8.net (直连)", "wenku8.cc (直连)", "CF Worker 中继"][index];
}

extension Wenku8NodeDesc on Wenku8Node {
  String get node => ["https://www.wenku8.net", "https://www.wenku8.cc", "https://666.zuohe233.work"][index];
}