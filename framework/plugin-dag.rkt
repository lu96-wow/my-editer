#lang racket

(require "../core/text/buffer.rkt"
         "../core/text/patch.rkt"
         rackunit)

;;; plugin-dag.rkt —— 插件 DAG 调度器（组合层唯一知道线程的地方）
;;;
;;; 插件是纯函数 buffer -> (listof patch)，**不知道线程**；
;;; 组合时用 plugin-spec 声明依赖（串行链 vs 独立并行）；
;;; 本模块按「依赖分层」调度：同层 future 真并行，层间串行。
;;; sync 阻塞返回最终 buffer；async 立即返回基线 + 结果句柄（版本失效判定）。
;;;
;;; 约定：
;;;   · 独立节点（无依赖边）写集不相交（各自不同 key）→ 并集合并无冲突
;;;   · 依赖图必须无环（compute-levels 会报错）
;;;   · sync/async 目前是「整张 DAG 一次跑」的两种跑法；按节点混合是后续步

(provide
 (struct-out plugin-spec)
 (struct-out plugin-async)
 (struct-out async-result)
 run-plugin-dag-sync
 run-plugin-dag-async
 run-plugin-dag-async-init
 plugin-async-poll
 plugin-dag-collect)

(struct plugin-spec (name plugin deps) #:transparent)
;; plugin : buffer -> (listof patch)   无状态 M 类
;; deps   : (listof name)              非空 = 串行链；空 = 独立可并行

;; ── 依赖分层：最长依赖深度 ──

(define (compute-levels specs)
  (define depmap (for/hash ([s specs]) (values (plugin-spec-name s) (plugin-spec-deps s))))
  (define memo (make-hash))
  (define visiting (make-hash))          ; 环检测
  (define (level name)
    (when (hash-ref visiting name #f)
      (error 'plugin-dag "依赖环: ~a" name))
    (cond
      [(hash-ref memo name #f) => identity]
      [else
       (hash-set! visiting name #t)
       (define l
         (if (null? (hash-ref depmap name '()))
             0
             (add1 (apply max (map level (hash-ref depmap name '()))))))
       (hash-remove! visiting name)
       (hash-set! memo name l)
       l]))
  (define lvls (for/hash ([s specs]) (values (plugin-spec-name s) (level (plugin-spec-name s)))))
  (define maxlvl (apply max 0 (hash-values lvls)))
  (for/list ([l (in-range (add1 maxlvl))])
    (for/list ([s specs] #:when (= l (hash-ref lvls (plugin-spec-name s)))) s)))

;; ── 同步：阻塞到整张 DAG 算完，返回最终 buffer ──

(define (run-plugin-dag-sync specs b0)
  (if (null? specs)
      b0
      (buffer-clean
       (for/fold ([b b0])
                 ([lvl (in-list (compute-levels specs))] #:when (pair? lvl))
         ;; 同层节点互不依赖 → 先把所有 future 建好，再统一 touch → 真并行
         (define fs (for/list ([s (in-list lvl)])
                      (future (lambda () ((plugin-spec-plugin s) b)))))
         (buffer-apply-patches b (apply append (map touch fs)))))))

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
(define (plugin-dag-collect current-buffer a)
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
    (list (plugin-spec 'token p-token '())
          (plugin-spec 'face  p-face  '())
          (plugin-spec 'diag  p-diag  '(token))))

  (define b1 (run-plugin-dag-sync specs b0))
  (check-equal? (buffer-get-text-property b1 0 0 'token) 'kw)
  (check-equal? (buffer-get-text-property b1 0 0 'face) 'blue)
  (check-equal? (buffer-get-text-property b1 0 0 'diag) "tok")  ; diag 看见了 token
  (check-false (buffer-dirty b1))                                ; dirty 被消费

  ;; 空 specs → 原样
  (check-eq? (run-plugin-dag-sync '() b0) b0)

  ;; 依赖环 → 报错
  (check-exn exn:fail?
             (lambda () (run-plugin-dag-sync
                         (list (plugin-spec 'a p-token '(b))
                               (plugin-spec 'b p-face  '(a)))
                         b0)))

  ;; async：无编辑 → 应用
  (define-values (b-ui async) (run-plugin-dag-async specs b0))
  (check-equal? (buffer-get-text-property (plugin-dag-collect b-ui async) 0 0 'diag) "tok")

  ;; async：期间编辑 → stale
  (define-values (b-ui2 async2) (run-plugin-dag-async specs b0))
  (define-values (b-edit _2) (buffer-insert b-ui2 0 0 #\Y))
  (check-equal? (plugin-dag-collect b-edit async2) 'stale)

  ;; 空 specs：async 无句柄
  (define-values (_b-empty a-empty) (run-plugin-dag-async '() b0))
  (check-false a-empty)

  ;; 启用时全量扫描：dirty 敏感的插件在 init 后仍产出（先 mark-dirty-all）
  (define (dirty-hl b)
    (if (buffer-dirty b) (list (patch 'face 0 0 (list (list 0 0 5 'bold)))) '()))
  (define-values (b-init a-init)
    (run-plugin-dag-async-init (list (plugin-spec 'hl dirty-hl '()))
                               (buffer-open "hello world")))
  (check-equal? (buffer-get-text-property (plugin-dag-collect b-init a-init) 0 0 'face) 'bold)

  (displayln "plugin-dag.rkt: all tests passed"))
