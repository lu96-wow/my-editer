#lang racket

;;; lab-rebuild/command.rkt —— 命令层（骨架）
;;;
;;; 职责：把**绑定键**映射到 handler，并提供「全局 + 按文档」两层组合。
;;; 本文件不 require core、不认识焦点、不认识按键怎么来 —— 只认 input.rkt 的绑定键。
;;;
;;;   command-table  binding → handler 的不可变表（一组命令）
;;;   command-set    global 表 + 每 did 的表；解析顺序 global 在前、did 在后（后覆盖前）
;;;
;;; handler 调用约定： (handler event ctx) —— event 原样透传（坐标 / 文本都在里面），
;;; ctx 由上层给（见 dispatch.rkt）。
;;;
;;; 设计待定（先记着，等拍）：
;;;   - handler 收 (event ctx) 还是收一个更结构化的 command-call？要不要把「不命中的回落」
;;;     （text / 可打印键自插入）也纳入本层，还是留给上层？
;;;   - 表的键除了 binding，是否还要带「模式」维度（这正是「输入是另一种转移状态」要接入
;;;     的地方）？当前靠 did 分层，模式留给上层。
;;;   - 命令是否需要「名字」（便于日志 / 重绑 / 显式调用），还是纯匿名 lambda 够用。

(provide command-table command-table? command-table-bindings
         command-add command-remove
         command-bound? command-table-empty? command-events command-merge
         command-lookup command-run
         ;; document 关联的命令集
         command-set command-set? command-set-global command-set-docs
         command-set-add-doc command-set-set-doc command-set-doc-tables command-set-tables
         command-set-lookup command-set-run)

;;; ================= 单表 =================

(struct command-table% (bindings) #:transparent)
;; bindings : 不可变 hash，binding -> handler

(define (command-table? x) (command-table%? x))
(define (command-table-bindings t) (command-table%-bindings t))

;; 交替 binding handler 构造；无参 → 空表。
(define (command-table . kvs)
  (unless (even? (length kvs))
    (error 'command-table "参数要成对：binding handler …，得到 ~a 个" (length kvs)))
  (let loop ([kvs kvs] [h (hash)])
    (cond
      [(null? kvs) (command-table% h)]
      [else (loop (cddr kvs) (hash-set h (car kvs) (cadr kvs)))])))

;; 加 / 删一条（返回新表）。
(define (command-add t b handler) (command-table% (hash-set (command-table-bindings t) b handler)))
(define (command-remove t b) (command-table% (hash-remove (command-table-bindings t) b)))

(define (command-bound? t b) (hash-has-key? (command-table-bindings t) b))
(define (command-table-empty? t) (zero? (hash-count (command-table-bindings t))))
(define (command-events t) (hash-keys (command-table-bindings t)))

;; 把一串表合成一个（后面的覆盖前面的）。
(define (command-merge tables)
  (command-table%
   (for/fold ([h (hash)]) ([t (in-list tables)])
     (for/fold ([h h]) ([(b handler) (in-hash (command-table-bindings t))])
       (hash-set h b handler)))))

;;; ================= 查 / 跑 =================
;;; tables : (listof command-table)，后面的优先级高。

;; 从后往前，返回第一个命中的 handler；都没有 → #f。
(define (command-lookup tables b)
  (for/or ([t (in-list (reverse tables))])
    (hash-ref (command-table-bindings t) b #f)))

;; 命中就 (apply handler args) 并返回 #t；没绑定 → #f。
(define (command-run tables b . args)
  (define handler (command-lookup tables b))
  (and handler (begin (apply handler args) #t)))

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
(define (command-set-run cs did b . args)
  (apply command-run (command-set-tables cs did) b args))
