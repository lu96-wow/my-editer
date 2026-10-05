#lang racket

;;; lab-rebuild/command/table.rkt —— 命令表机制（骨架，纯）
;;;
;;; 职责：把**绑定键**映射到**命令描述**，并提供「全局 + 按文档」两层组合。
;;; 本文件不认识 core / 焦点 / 按键怎么来，也**不认识命令名什么意思** ——
;;; 命令描述是给 command/registry 解释的不透明值：
;;;
;;;   spec = symbol              （命令名）
;;;        | (list symbol arg …)  （带参数：如 (prefix "C-p" table) / (insert-string "\n")）
;;;
;;;   command-table  binding → spec 的不可变表（一组命令）
;;;   command-set    global 表 + 每 did 的表；解析顺序 global 在前、did 在后（后覆盖前）
;;;
;;; 「谁跑」在 command/registry；「按 did / 模态选表」在 command/dispatch。

(provide command-table command-table? command-table-bindings
         command-add command-remove
         command-bound? command-table-empty? command-events command-merge
         command-lookup
         ;; document 关联的命令集
         command-set command-set? command-set-global command-set-docs
         command-set-add-doc command-set-set-doc command-set-doc-tables command-set-tables
         command-set-lookup)

;;; ================= 单表 =================

(struct command-table% (bindings) #:transparent)
;; bindings : 不可变 hash，binding -> spec

(define (command-table? x) (command-table%? x))
(define (command-table-bindings t) (command-table%-bindings t))

;; 交替 binding spec 构造；无参 → 空表。
(define (command-table . kvs)
  (unless (even? (length kvs))
    (error 'command-table "参数要成对：binding spec …，得到 ~a 个" (length kvs)))
  (let loop ([kvs kvs] [h (hash)])
    (cond
      [(null? kvs) (command-table% h)]
      [else (loop (cddr kvs) (hash-set h (car kvs) (cadr kvs)))])))

(define (command-add t b spec) (command-table% (hash-set (command-table-bindings t) b spec)))
(define (command-remove t b) (command-table% (hash-remove (command-table-bindings t) b)))

(define (command-bound? t b) (hash-has-key? (command-table-bindings t) b))
(define (command-table-empty? t) (zero? (hash-count (command-table-bindings t))))
(define (command-events t) (hash-keys (command-table-bindings t)))

;; 把一串表合成一个（后面的覆盖前面的）。
(define (command-merge tables)
  (command-table%
   (for/fold ([h (hash)]) ([t (in-list tables)])
     (for/fold ([h h]) ([(b spec) (in-hash (command-table-bindings t))])
       (hash-set h b spec)))))

;;; ================= 查 =================
;;; tables : (listof command-table)，后面的优先级高。

;; 从后往前，返回第一个命中的 spec；都没有 → #f。
(define (command-lookup tables b)
  (for/or ([t (in-list (reverse tables))])
    (hash-ref (command-table-bindings t) b #f)))

;;; ================= document 关联的命令集 =================

(struct command-set% (global docs) #:transparent)
;; global : (listof command-table)                所有文档都生效
;; docs   : 不可变 hash did -> (listof command-table)

(define (command-set [global '()]) (command-set% global (hash)))
(define (command-set? x) (command-set%? x))
(define (command-set-global cs) (command-set%-global cs))
(define (command-set-docs cs) (command-set%-docs cs))

(define (command-set-set-doc cs did tables)
  (command-set% (command-set-global cs) (hash-set (command-set-docs cs) did tables)))
(define (command-set-add-doc cs did t)
  (command-set-set-doc cs did (append (command-set-doc-tables cs did) (list t))))
(define (command-set-doc-tables cs did)
  (hash-ref (command-set-docs cs) did '()))

;; 某文档实际生效的表：global + 该 did 自己的。
(define (command-set-tables cs did)
  (append (command-set-global cs) (command-set-doc-tables cs did)))

(define (command-set-lookup cs did b) (command-lookup (command-set-tables cs did) b))
