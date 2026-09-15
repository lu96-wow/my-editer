#lang racket

;; ═══════════════════════════════════════════════════════════════════════
;; 并行/串行插件管线 —— 单文件设计展示（不动编辑器代码）
;;
;; 展示的设计要点：
;;   1. 插件是纯函数 `doc -> (listof patch)`，**完全不知道线程**。
;;   2. 组合时声明「依赖」：有依赖 = 串行链；无依赖 = 独立可并行。
;;   3. sync / async 是**组合层**的执行方式，与依赖结构正交。
;;   4. 独立分支的合并 = 补丁并集（前提：写集不相交，annotator 约定）。
;;   5. async 用「版本号 rev」做失效判定：算完时文档已变 → 丢投影。
;;
;; 运行：  racket plugin-pipeline-demo.rkt
;; ═══════════════════════════════════════════════════════════════════════

(require racket/list)

;; ───────────────────────── 1. 数据 ─────────────────────────

;; 补丁：一段标注 delta。key 决定归属（不同插件写不同 key，才能并集合并）。
(struct patch (key start end val) #:transparent)

;; 极简 doc：文本 + 已应用标注（按 key 分组）+ 单调版本号。
;;   props : (hashof key (listof (list start end val)))
;;   rev   : 用户编辑才 +1；插件应用标注不 +1（用于 async 失效判定）。
(struct doc (text props rev) #:transparent)

(define (doc-empty [text ""]) (doc text (hash) 0))

;; 用户编辑：改文本，rev +1。
(define (user-edit d text)
  (struct-copy doc d [text text] [rev (add1 (doc-rev d))]))

;; 把一批补丁并进 doc。key 不相交时，这个「合并」与顺序无关。
(define (apply-patches d ps)
  (struct-copy doc d
    [props
     (for/fold ([m (doc-props d)]) ([p (in-list ps)])
       (hash-update m (patch-key p)
                    (λ (old) (append old (list (list (patch-start p)
                                                     (patch-end p)
                                                     (patch-val p)))))
                    '()))]))

;; ───────────────────────── 2. 组合声明（核心语法） ─────────────────────────
;;
;;   (pnode 名字 纯函数 依赖列表)
;;
;;   · 依赖非空 → 串行链：该节点的输入 = 「祖先补丁已应用后的 doc」
;;   · 依赖为空 → 独立节点：可并行，最终合并 = 补丁并集
;;
;; 注意：下面三个插件里没有任何线程/调度概念，是纯粹的 in→out。
;; ═══════════════════════════════════════════════════════════════════════
(struct pnode (name fn deps) #:transparent)

;; a：分词 → 产出 'token 标注
(define (tokenize d)
  (sleep 0.3)                       ; 假装要做点活，便于观察并行
  (list (patch 'token 0 6 'kw)
        (patch 'token 7 8 'var)))

;; b：高亮 → 依赖 a 的 'token，读出 token 区间再产出 'face
(define (highlight d)
  (sleep 0.3)
  (for/list ([t (in-list (hash-ref (doc-props d) 'token '()))])
    (patch 'face (list-ref t 0) (list-ref t 1)
           (if (eq? (list-ref t 2) 'kw) 'blue 'cyan))))

;; c：诊断 → 独立，只看原文，产出 'diag
(define (diagnostics d)
  (sleep 0.3)
  (list (patch 'diag 0 6 "未使用")))

;; 组合：a→b 是一个串行整体；c 与它并行。
(define pipeline
  (list
   (pnode 'tokenize    tokenize    '())          ; 独立 → 并行
   (pnode 'highlight   highlight   '(tokenize))  ; 依赖 a → 串行在其后
   (pnode 'diagnostics diagnostics '())))        ; 独立 → 并行

;; 同一个声明系统，改「依赖列表」就能表达其它拓扑：
;;   · 全串行： (pnode 'a .. '()) (pnode 'b .. '(a)) (pnode 'c .. '(b))
;;   · 全并行： (pnode 'a .. '()) (pnode 'b .. '()) (pnode 'c .. '())

;; ───────────────────────── 3. 调度器（唯一知道线程的地方） ─────────────────────────

;; 按「最长依赖深度」分层：同层节点互不依赖 → 可并行；层之间串行。
(define (compute-levels nodes)
  (define depmap (for/hash ([n nodes]) (values (pnode-name n) (pnode-deps n))))
  (define memo (make-hash))                     ; 调度器内部可用可变结构，插件不许
  (define (level name)
    (cond
      [(hash-ref memo name #f) => identity]
      [else
       (define l
         (if (null? (hash-ref depmap name '()))
             0
             (add1 (apply max (map level (hash-ref depmap name '()))))))
       (hash-set! memo name l)
       l]))
  (define lvls (for/hash ([n nodes]) (values (pnode-name n) (level (pnode-name n)))))
  (define maxlvl (apply max 0 (hash-values lvls)))
  (for/list ([l (in-range (add1 maxlvl))])
    (for/list ([n nodes] #:when (= l (hash-ref lvls (pnode-name n)))) n)))

;; 同步：阻塞到整张 DAG 算完，一次性返回最终 doc。
(define (run-sync nodes base)
  (for/fold ([d base])
            ([lvl (in-list (compute-levels nodes))] #:when (pair? lvl))
    ;; 关键：先把本层所有 future 都创建出来，再统一 touch → 才是真并行。
    (define fs (for/list ([n (in-list lvl)])
                 (future (λ () ((pnode-fn n) d)))))
    (apply-patches d (apply append (map touch fs)))))

;; 异步：不等待。立即返回「基线 doc」（UI 先画它）+ 结果通道（算完再收）。
(define (run-async nodes base)
  (define ch (make-channel))
  (thread (λ () (channel-put ch (run-sync nodes base))))
  (values base ch))

;; 收结果：若结果 rev == 当前文档 rev → 期间无用户编辑，应用；否则丢投影。
(define (collect current-doc ch)
  (define result (channel-get ch))
  (if (= (doc-rev result) (doc-rev current-doc))
      result
      'stale))

;; ───────────────────────── 4. 演示 ─────────────────────────

(module+ main
  (define base (doc-empty "define x"))

  ;; ---- 同步：观察 (a∥c) 再 b 的耗时 ----
  (define t0 (current-inexact-monotonic-milliseconds))
  (define d1 (run-sync pipeline base))
  (define t1 (current-inexact-monotonic-milliseconds))
  (printf "【sync】总耗时 ~ams（每插件 0.3s：a∥c 并行 → b 串行，≈0.6s 而非 0.9s）~n"
          (- t1 t0))
  (printf "        最终标注: ~s~n~n" (doc-props d1))

  ;; ---- 异步：立即渲染基线，算完再应用 ----
  (define-values (d-ui ch) (run-async pipeline base))
  (printf "【async】UI 立即拿到基线 rev=~a（先渲染），后台计算中…~n" (doc-rev d-ui))

  ;; 情况 A：期间用户编辑了 → 投影失效
  (define d-edit (user-edit d-ui "define y"))
  (printf "        用户编辑 → rev=~a~n" (doc-rev d-edit))
  (printf "        后台结果: ~s   ← 失效，丢弃投影（状态不会丢，只是这条渲染图不要了）~n~n"
          (collect d-edit ch))

  ;; 情况 B：期间无编辑 → 投影有效
  (define-values (d-ui2 ch2) (run-async pipeline base))
  (printf "【async】无编辑：后台结果 ~s~n"
          (doc-props (collect d-ui2 ch2))))
