把第三方 apk 源的签名公钥（*.pub 或 *.rsa.pub）放这个目录。
build25.sh 会自动把它们拷到 imagebuilder 的 keys/ 目录。
没有对应公钥的话，apk 会以 UNTRUSTED signature 拒绝安装该源的包。
（本目录为空时构建不受任何影响）
