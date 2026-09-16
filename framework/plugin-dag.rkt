#lang racket

(require "../core/text/buffer.rkt"
         "../core/text/patch.rkt"
         "deps.rkt" rackunit)

;;; plugin-dag.rkt —— 插件 DAG 调度器（组合层唯一知道线程的地方）
;;;
;;; 插件只有一种：buffer -> (listof patch)。**不知道线程**。
;;;   · stateful 是「闭包是否带内部状态」，不是类型——带 box 的闭包就是 stateful 插件。
;;;   · 线程是统一的可选 mode：'sync（内联）| 'parallel（future）| 整轮 async。
;;; 组合时用 plugin-spec 声明依赖（串行链 vs 独立并行）与 mode。
;;; 本模块按「依赖分层」调度：同层 'parallel 用 future，'sync 内联。
;;; sync 阻塞返回最终 buffer；async 立即返回基线 + 结果句柄（版本失效判定）。
;;;
;;; 约定：
;;;   · 独立节点（无依赖边）写集不相交（各自不同 key）→ 并集合并无冲突
;;;   · 依赖图必须无环（compute-levels 会报错）
;;;   · 'parallel/'async 要求插件纯（不写共享可变 box）；带状态的闭包用 'sync

(provide
 (struct-out plugin-spec)
 (struct-out plugin-async)
 (struct-out async-result)
 run-plugin-dag-sync
 run-plugin-dag-async
 run-plugin-dag-async-init
 plugin-async-poll
 plugin-async-collect)

(struct plugin-spec (name plugin deps mode) #:transparent)
;; plugin : buffer -> (listof patch)   （闭包可捕获内部状态 = stateful）
;; deps   : (listof name)              非空 = 串行链；空 = 独立可并行
;; mode   : 'sync（默认，内联无线程）| 'parallel（future 真并行）

;; ── 依赖分层：最长依赖深度（见 deps.rkt） ──

;; ── 同步：阻塞到整张 DAG 算完，返回最终 buffer ──

(define (run-plugin-dag-sync specs b0)
  (if (null? specs)
      b0
      (begin
        ;; mode 只允许 'sync | 'parallel；'async 是「整轮不阻塞」的行为，
        ;; 不是单插件 mode（见 run-plugin-dag-async）。非法 mode 要报错，不能静默丢弃。
        (for ([s (in-list specs)])
          (unless (memq (plugin-spec-mode s) '(sync parallel))
            (error 'plugin-dag "plugin ~a: 非法 mode ~a（允许 'sync | 'parallel；async 用 run-plugin-dag-async）"
                   (plugin-spec-name s) (plugin-spec-mode s))))
        (buffer-clean
         (for/fold ([b b0])
                   ([lvl (in-list (compute-levels specs plugin-spec-name plugin-spec-deps))] #:when (pair? lvl))
           ;; 同层节点互不依赖。'parallel 用 future（先建好再统一 touch）；
           ;; 'sync 直接内联——线程是可选的，默认无线程开销。
           (define parallel (filter (lambda (s) (eq? (plugin-spec-mode s) 'parallel)) lvl))
           (define sync     (filter (lambda (s) (eq? (plugin-spec-mode s) 'sync))     lvl))
           (define pfs (for/list ([s (in-list parallel)])
                         (future (lambda () ((plugin-spec-plugin s) b)))))
           (define spatches (apply append (for/list ([s (in-list sync)]) ((plugin-spec-plugin s) b))))
           (define ppatches (apply append (map touch pfs)))
           (buffer-apply-patches b (append spatches ppatches)))))))

;; ── 异步：不等待。立即返回基线（先渲染）+ 结果句柄 ──

;; 进行中的异步计算：base-buffer = 启动时的快照，ch = 结果通道。
(struct plugin-async (base-buffer ch) #:transparent)

;; 回 UI 的消息：某次异步插件算完，base-buffer → buffer（内容不变，只加了标注）。
(struct async-result (base-buffer buffer) #:transparent)

(define (run-plugin-dag-async specs b0)
  (if (null? specs)
      (values b0 #f)
      (let ([ch (make-channel)])
        (thread (lambda () (channel-put ch (run-plugin-dag-sync specs b0))))
        (values b0 (plugin-async b0 ch)))))

;; 启用时全量扫描：先标全量 dirty，再异步跑（对应 run-plugins-init 的 async 版）。
(define (run-plugin-dag-async-init specs b0)
  (if (null? specs)
      (values b0 #f)
      (run-plugin-dag-async specs (buffer-mark-dirty-all b0))))

;; 非阻塞：没算完 → #f；算完 → 结果 buffer。
(define (plugin-async-poll a)
  (channel-try-get (plugin-async-ch a)))

;; 收结果（阻塞）：期间内容没变 → 应用；变了 → stale（丢投影，重算由调用者决定）。
(define (plugin-async-collect a current-buffer)
  (define result (channel-get (plugin-async-ch a)))
  (if (buffer-content-same? (plugin-async-base-buffer a) current-buffer)
      result
      'stale))

(module+ test
  (define-values (b0 _) (buffer-insert (buffer-open "hello world") 0 0 #\X)) ; 置 dirty

  ;; 三个插件：token / face 独立并行；diag 依赖 token（串行在其后）
  (define (p-token b) (list (patch 'token 0 0 (list (list 0 0 5 'kw)))))
  (define (p-face  b) (list (patch 'face  0 0 (list (list 0 0 5 'blue)))))
  (define (p-diag  b)
    (list (patch 'diag 0 0
                 (list (list 0 0 5
                             (if (buffer-get-text-property b 0 0 'token) "tok" "none"))))))
  (define specs
    (list (plugin-spec 'token p-token '() 'sync)
          (plugin-spec 'face  p-face  '() 'sync)
          (plugin-spec 'diag  p-diag  '(token) 'sync)))

  (define b1 (run-plugin-dag-sync specs b0))
  (check-equal? (buffer-get-text-property b1 0 0 'token) 'kw)
  (check-equal? (buffer-get-text-property b1 0 0 'face) 'blue)
  (check-equal? (buffer-get-text-property b1 0 0 'diag) "tok")  ; diag 看见了 token
  (check-false (buffer-dirty b1))                                ; dirty 被消费

  ;; 空 specs → 原样
  (check-eq? (run-plugin-dag-sync '() b0) b0)

  ;; 非法 mode → 报错（不能静默丢弃插件）
  (check-exn exn:fail?
             (lambda () (run-plugin-dag-sync (list (plugin-spec 'x p-token '() 'async)) b0)))

  ;; 依赖环 → 报错
  (check-exn exn:fail?
             (lambda () (run-plugin-dag-sync
                         (list (plugin-spec 'a p-token '(b) 'sync)
                               (plugin-spec 'b p-face  '(a) 'sync))
                         b0)))

  ;; parallel 模式：同层 future 并行（功能与 sync 一致，线程可选用）
  (define specs-par
    (list (plugin-spec 'token p-token '() 'parallel)
          (plugin-spec 'face  p-face  '() 'parallel)
          (plugin-spec 'diag  p-diag  '(token) 'sync)))
  (check-equal? (buffer-get-text-property (run-plugin-dag-sync specs-par b0) 0 0 'face) 'blue)
  (check-equal? (buffer-get-text-property (run-plugin-dag-sync specs-par b0) 0 0 'diag) "tok")

  ;; async：无编辑 → 应用
  (define-values (b-ui async) (run-plugin-dag-async specs b0))
  (check-equal? (buffer-get-text-property (plugin-async-collect async b-ui) 0 0 'diag) "tok")

  ;; async：期间编辑 → stale
  (define-values (b-ui2 async2) (run-plugin-dag-async specs b0))
  (define-values (b-edit _2) (buffer-insert b-ui2 0 0 #\Y))
  (check-equal? (plugin-async-collect async2 b-edit) 'stale)

  ;; 空 specs：async 无句柄
  (define-values (_b-empty a-empty) (run-plugin-dag-async '() b0))
  (check-false a-empty)

  ;; 启用时全量扫描：dirty 敏感的插件在 init 后仍产出（先 mark-dirty-all）
  (define (dirty-hl b)
    (if (buffer-dirty b) (list (patch 'face 0 0 (list (list 0 0 5 'bold)))) '()))
  (define-values (b-init a-init)
    (run-plugin-dag-async-init (list (plugin-spec 'hl dirty-hl '() 'sync))
                               (buffer-open "hello world")))
  (check-equal? (buffer-get-text-property (plugin-async-collect a-init b-init) 0 0 'face) 'bold)

  ;; stateful = 闭包（带 box），不是单独类型；同一闭包多次调用状态累计
  (define (make-invoke-counter)
    (define n (box 0))
    (lambda (b)
      (set-box! n (add1 (unbox n)))
      (list (patch 'count 0 0 (list (list 0 0 1 (unbox n)))))))
  (define counter (make-invoke-counter))
  (define r1 (run-plugin-dag-sync (list (plugin-spec 'c counter '() 'sync)) (buffer-open "a")))
  (check-equal? (buffer-get-text-property r1 0 0 'count) 1)
  (define r2 (run-plugin-dag-sync (list (plugin-spec 'c counter '() 'sync)) (buffer-open "b")))
  (check-equal? (buffer-get-text-property r2 0 0 'count) 2)   ; 闭包状态跨调用累计

  (displayln "plugin-dag.rkt: all tests passed"))
