#lang racket

;;; edit4/config/sync.rkt —— 双文档映射同步的词表（纯数据）
;;;
;;; mapping = (list id a-lang b-lang terms)
;;;   terms = (listof (cons a-term b-term))；a-lang → b-lang 为正方向。
;;; 初版：英文 Racket ↔ 中文 Racket 关键字。未列出的词不映射（identity 兜底）。
;;; 只改「代码位置」的符号 token；字符串 / 注释 / 数字不动（transform.rkt 负责）。
;;; terms 必须是部分双射：一个词不能同时映到两个不同的词（否则 round-trip 会漂）。

(provide sync-mappings)

(define sync-mappings
  (list
   (list 'rkt-zh 'rkt 'zh
         '(("define" . "定义")
           ("define-values" . "定义-多值")
           ("lambda" . "函数")
           ("let" . "令")
           ("let*" . "令*")
           ("letrec" . "令递归")
           ("if" . "如果")
           ("cond" . "分支")
           ("when" . "当")
           ("unless" . "除非")
           ("begin" . "开始")
           ("set!" . "设置!")
           ("quote" . "引用")
           ("and" . "与")
           ("or" . "或")
           ("not" . "非")
           ("map" . "映射")
           ("for" . "循环")
           ("for/list" . "循环/列表")
           ("display" . "显示")
           ("displayln" . "显示行")
           ("newline" . "换行")
           ("printf" . "格式打印")
           ("values" . "多值")
           ("call/cc" . "调用/续延")
           ("error" . "报错")))))
