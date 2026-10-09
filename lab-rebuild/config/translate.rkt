#lang racket

;;; lab-re-rebuild/config/translate.rkt —— 对照翻译词典（纯数据）。
;;;
;;; 每条 = (源词 . 译词)。按「整个词」匹配（见 builtin/translate.rkt 的词法），
;;; 不匹配子串；译词里不能含换行（保证逐行保持行数）。
;;; 反向翻译用同一张表的逆：译词必须唯一，否则后出现者覆盖先出现者。

(provide translate-pairs)

(define translate-pairs
  (list
   ;; C 常见
   (cons "printf"   "打印")
   (cons "display"  "显示")
   (cons "scanf"    "扫描")
   (cons "malloc"   "分配")
   (cons "free"     "释放")
   (cons "return"   "返回")
   (cons "break"    "中断")
   (cons "continue" "继续")
   (cons "include"  "包含")
   (cons "define"   "定义")
   (cons "struct"   "结构")
   (cons "typedef"  "类型定义")
   (cons "sizeof"   "长度")
   (cons "int"      "整数")
   (cons "char"     "字符")
   (cons "void"     "空")
   (cons "float"    "浮点")
   (cons "double"   "双精度")
   (cons "long"     "长整")
   (cons "short"    "短整")
   (cons "unsigned" "无符号")
   (cons "const"    "常量")
   (cons "static"   "静态")
   ;; 控制流
   (cons "if"       "如果")
   (cons "else"     "否则")
   (cons "while"    "当")
   (cons "for"      "循环")
   (cons "switch"   "分支")
   (cons "case"     "情况")
   (cons "default"  "默认")
   (cons "true"     "真")
   (cons "false"    "假")
   (cons "null"     "空值")))
