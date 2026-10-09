#lang racket

;;; edit/keymap.rkt —— 键表（纯）：绑定键 -> spec
;;;
;;; spec 可以是
;;;     · 一个 cmd 值（静态绑定）
;;;     · 一个 (event -> cmd) 过程（需要事件数据的绑定，如 resize / 文本 / 鼠标）
;;;     · 一个 prefix（多键序列的前缀，如 C-p 后接方向）
;;;
;;; 组合：keytable-merge 后面的覆盖前面的；session 里可放一叠键表（上下文），
;;; 查找自上而下，第一个命中的赢。


(provide (struct-out keymap) (struct-out prefix)
         kbd keymap-lookup keymap-merge keymap-add)

(struct keymap (bindings) #:transparent)
;; bindings : (hash binding -> spec)

;; 多键前缀：命中后把 keymap 设为下一层的活动键表（可嵌套）。
(struct prefix (label keymap) #:transparent)
;; label  : string   显示用（如 "C-p"）

;; 便捷构造：(kbd (key 'a 'ctrl) spec  binding spec …)
(define (kbd . kvs)
  (unless (even? (length kvs)) (error 'kbd "参数要成对（binding spec …），得到 ~a 个" (length kvs)))
  (keymap (for/hash ([i (in-range 0 (length kvs) 2)])
            (values (list-ref kvs i) (list-ref kvs (add1 i))))))

;; 查一个绑定键；#f = 无。
(define (keymap-lookup km b)
  (and km b (hash-ref (keymap-bindings km) b #f)))

;; 合并：后面的覆盖前面的。
(define (keymap-merge kms)
  (keymap
   (for/fold ([h (hash)]) ([km (in-list kms)])
     (for/fold ([h h]) ([(b s) (in-hash (keymap-bindings km))])
       (hash-set h b s)))))

;; 单点绑定（document 打开时补键用）。
(define (keymap-add km b spec)
  (keymap (hash-set (keymap-bindings km) b spec)))
