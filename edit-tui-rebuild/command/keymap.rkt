#lang racket

;;; layer  : command
;;; effect : 无（纯 trie）

;;; command/keymap.rkt —— 表（trie）+ 表列表操作对象
;;;
;;; token 是不透明、equal? 可比的值（键令牌、鼠标令牌…）。
;;;
;;; 一张 **keymap（表）** 是一棵 trie：
;;;     叶子   command   命中即执行（命令记录：run / note / input）
;;;     子树   keymap   前缀，继续读键
;;;
;;; 一个 **keytable（操作对象）** 是「表的列表」。它只有两个操作 API：
;;;
;;;   (keytable-merge! kt km ...)   把若干张表合并进来
;;;   (keytable-lookup kt seq)      在一串 token（前缀序列）上查表
;;;
;;; 另有给 state 层用的查询：
;;;   (keytable-hints kt prefix)    当前前缀下紧接一步的选项（which-key）
;;;   (keytable-commands kt prefix) 当前前缀下所有完整绑定（帮助 / 补全）
;;;
;;; 以及一个**纯序列匹配器** matcher：吃 token，记住「正在匹配的序列」。
;;; 外部状态机可以不碰 event / tui，直接用它：
;;;   (define m (make-matcher kt))
;;;   (matcher-feed! m (key 'x 'ctrl))  ; => 'prefix
;;;   (matcher-pending m)               ; => 正在匹配的序列
;;;   (matcher-feed! m (key 's 'ctrl))  ; => 'command + command
;;;
;;; 说明与输入需求都存在叶子 command 上（见 command.rkt），查表即得。
;;;
;;; 表列表是**运行时可变**的：`keytable-merge!` 之后，所有持有同一个 keytable
;;; 的读键器立刻看到新表；调用方也可以直接 `set-keytable-tables!` 换掉整份表。
;;;
;;; 合并**有冲突直接 error**（不再「后表覆盖前表」）。冲突 = 同一条 token 序列
;;; 被两个表同时占用：
;;;   · 两条相同序列都有叶子（两个过程抢同一个键）；
;;;   · 同一序列上一张表是叶子、另一张是子树（一个过程遮住更长的序列）。
;;; 两边都是子树则继续往下比：C-x C-s 与 C-x C-c 可以共存（前缀 C-x 是共享的）。
;;;
;;; 构造 DSL `keys`：每条绑定写成一对方括号，最后一格是过程，前面是要按的 token。
;;;
;;;     (keys [(key 'left)                 (λ () …)]
;;;           [(key 'x 'ctrl) (key 's 'ctrl) (λ () …)]
;;;           [(mouse 'press 'left)        (λ () …)])
;;;
;;; 宿主读到事件后喂 `keytable-lookup`；空表用 `(make-keytable)`。

(provide keys
         (struct-out keytable)
         make-keytable
         keytable-merge!
         keytable-lookup
         keytable-hints
         keytable-commands
         (struct-out matcher)
         make-matcher
         matcher-feed!
         matcher-reset!
         matcher-pending
         (all-from-out "command.rkt"))

(require "command.rkt")

;;; ════════════════════════ 表（trie，纯） ════════════════════════

;; token 由调用方给：键用 (key …)，鼠标用 (mouse …)。表本身不关心 token 类型。
(struct keymap (bindings) #:transparent)
;; bindings : (hash/c any/c (or/c keymap? command?))   ; 键 = 任意 equal? 可比 token

(define empty-keymap (keymap (hash)))

;; 插入一条 seq → 命令叶子。路径上的旧叶子 / 旧子树按「后插覆盖」处理（构表内部用）。
(define (keymap-set km seq leaf)
  (unless (pair? seq)
    (error 'keymap-set "序列要是非空 token 列表，得到 ~a" seq))
  (unless (command? leaf)
    (error 'keymap-set "叶子要是一个 command，得到 ~a" leaf))
  (define (go h seq)
    (define k (car seq))
    (if (null? (cdr seq))
        (hash-set h k leaf)
        (let* ([sub (hash-ref h k #f)]
               [sub* (if (keymap? sub) sub empty-keymap)])
          (hash-set h k (keymap (go (keymap-bindings sub*) (cdr seq)))))))
  (keymap (go (keymap-bindings km) seq)))

;; 单步查一个键 → 子树 | command | #f
(define (keymap-lookup km k)
  (and km (hash-ref (keymap-bindings km) k #f)))

;; 精确查一条完整序列 → command | #f（序列前缀对但没到底 → #f）
(define (keymap-ref km seq)
  (let loop ([cur km] [seq seq])
    (cond [(null? seq) (and (command? cur) cur)]
          [(not (keymap? cur)) #f]
          [else (loop (keymap-lookup cur (car seq)) (cdr seq))])))

;; 沿 seq 走到节点 → 子树 | #f。空 seq 得到根。
(define (keymap-navigate km seq)
  (let loop ([cur km] [seq seq])
    (cond [(null? seq) (and (keymap? cur) cur)]
          [(not (keymap? cur)) #f]
          [else (define e (keymap-lookup cur (car seq)))
                (and e (loop e (cdr seq)))])))

;; 这条序列是不是某条更长绑定的前缀（走到子树）？
(define (keymap-prefix? km seq)
  (and (keymap-navigate km seq) #t))

;; 两棵表的冲突序列（listof token）| #f。见文件头「冲突」定义。
(define (keymap-conflict-seq a b)
  (define (node-conflict ea eb rev-prefix)
    (cond
      [(and (keymap? ea) (keymap? eb))
       (for/or ([(k eb*) (in-hash (keymap-bindings eb))])
         (define ea* (hash-ref (keymap-bindings ea) k #f))
         (and ea* (node-conflict ea* eb* (cons k rev-prefix))))]
      [else (reverse rev-prefix)]))          ; 叶子 vs 叶子 / 叶子 vs 子树
  (for/or ([(k eb) (in-hash (keymap-bindings b))])
    (define ea (hash-ref (keymap-bindings a) k #f))
    (and ea (node-conflict ea eb (list k)))))

;;; ════════════════════════ 操作对象：表列表 ════════════════════════

(struct keytable (tables) #:transparent #:mutable)
;; tables : (listof keymap)  按加入顺序；查找时逐张扫

;; 空表，或直接带若干张初始表（一样走冲突检查）。
(define (make-keytable . kms)
  (apply keytable-merge! (keytable '()) kms))

;; 合并若干张表。任何冲突 → error，且**不改动** kt（原子）。
(define (keytable-merge! kt . kms)
  (for ([km (in-list kms)])
    (unless (keymap? km)
      (error 'keytable-merge! "要合并的是 keymap（keys 构造），得到 ~a" km)))
  (define seen (keytable-tables kt))
  (for ([km (in-list kms)])
    (for ([other (in-list seen)])
      (define seq (keymap-conflict-seq other km))
      (when seq
        (error 'keytable-merge! "键表冲突：序列 ~v 被重复绑定" seq)))
    (set! seen (cons km seen)))
  (set-keytable-tables! kt (append (keytable-tables kt) kms))
  kt)

;; 查一条完整 token 序列，逐张表扫。
;;   (values 'command cmd)   某张表精确命中命令
;;   (values 'prefix  #f)    没有命令，但有表以该序列为前缀（还有续键）
;;   (values 'unbound #f)    哪张表都没有这条路径
(define (keytable-lookup kt seq)
  (define tables (keytable-tables kt))
  (cond
    [(for/or ([km (in-list tables)]) (keymap-ref km seq))
     => (λ (cmd) (values 'command cmd))]
    [(for/or ([km (in-list tables)]) (keymap-prefix? km seq))
     (values 'prefix #f)]
    [else (values 'unbound #f)]))

;;; ════════════════════════ 纯序列匹配器（无 event / tui） ════════════════════════

(struct matcher (table typed) #:transparent #:mutable)
;; table : keytable          活动表（可变；运行时并表立刻生效）
;; typed : (listof token)    已按下的前缀（正序）——**正在匹配的序列**

(define (make-matcher kt) (matcher kt '()))

;; 喂一个 token → (values status entry)
;;   'command cmd : 命中，typed 清空
;;   'prefix  #f  : 还是前缀，typed 追加
;;   'unbound #f  : 没命中，typed 清空
(define (matcher-feed! m tok)
  (define typed (append (matcher-typed m) (list tok)))
  (define-values (status entry) (keytable-lookup (matcher-table m) typed))
  (case status
    [(command) (matcher-reset! m) (values 'command entry)]
    [(prefix) (set-matcher-typed! m typed) (values 'prefix #f)]
    [else (matcher-reset! m) (values 'unbound #f)]))

(define (matcher-reset! m) (set-matcher-typed! m '()))

;; 正在匹配的序列（token 列表）| #f
(define (matcher-pending m)
  (define t (matcher-typed m))
  (and (pair? t) t))

;; 当前前缀下**紧接一步**的选项，跨表按 token 合并（which-key 用）。
;; => (list (cons token cmd-or-#f) ...)   ; #f = 这步是前缀，还能继续
(define (keytable-hints kt [prefix '()])
  (define by-token (make-hash))
  (for ([km (in-list (keytable-tables kt))])
    (define node (keymap-navigate km prefix))
    (when (keymap? node)
      (for ([(k leaf) (in-hash (keymap-bindings node))])
        (define prev (hash-ref by-token k 'absent))
        (cond [(eq? prev 'absent) (hash-set! by-token k (and (command? leaf) leaf))]
              [(and prev (command? leaf)) (void)]   ; 两边都是叶子：冲突检查本该拦住
              [else (hash-set! by-token k #f)]))))
  (sort (for/list ([(k v) (in-hash by-token)]) (cons k v))
        string<? #:key (λ (p) (~v (car p)))))

;; 当前前缀下所有可达的**完整绑定**（帮助 / 命令列表用）。
;; => (list (cons (listof token) cmd) ...)，按序列稳定排序
(define (keytable-commands kt [prefix '()])
  (define out '())
  (for ([km (in-list (keytable-tables kt))])
    (define node (keymap-navigate km prefix))
    (when (keymap? node)
      (define (walk n rev)
        (for ([(k leaf) (in-hash (keymap-bindings n))])
          (define rev* (cons k rev))
          (if (keymap? leaf)
              (walk leaf rev*)
              (set! out (cons (cons (reverse rev*) leaf) out)))))
      (walk node (reverse prefix))))
  (sort out string<? #:key (λ (p) (~v (car p)))))

;;; ════════════════════════ 构造 DSL ════════════════════════

;; keys：[seq … proc] —— 最后一格是过程，其余是 token 序列。产出一张表。
(define-syntax keys
  (syntax-rules ()
    [(_ [seq ... proc] ...)
     (keymap-from-bindings (list (list (list seq ...) proc) ...))]))

(define (keymap-from-bindings binds)
  (for/fold ([km empty-keymap]) ([b (in-list binds)])
    (keymap-set km (car b) (->command (cadr b)))))
