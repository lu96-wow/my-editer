#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/attr.rkt" "../atom/change.rkt" rackunit)

;;; unit/history.rkt —— 撤销/重放账本
;;;
;;; 归属：文本与属性变更都走 文档；本模块只管账本——记不记、和谁并、几步。
;;; 所以它是**纯数据**：不碰 窗口/文档，只认识 变更 / 编辑-描述 / 位置。
;;;
;;; 一步必须自含正反两向：
;;;   重放 : (listof 变更)  重放：**正序依次施加**（每条坐标基于上一条之后）
;;;   撤销   : (listof 变更)  撤销：正序依次施加
;;;   前-位置 : 位置         该步开始前 活动 视图的光标
;;;
;;; 一步是 变更 的**序列**而非单个 变更：连续打字合并成一步时，每条 描述 的坐标
;;; 都基于前一条之后，不能塞进一个批语义的 变更。
;;;
;;; ⚠ 逆必须由**编辑前**的 缓冲 导出（见 doc/document.rkt 的 变更-结果）。
;;; 用编辑后的 缓冲 求逆会静默写坏历史；属性的逆还必须额外补回被文本抹掉的段。
;;;
;;; 合并规则（结构判定，无时钟无状态）：只对**纯文本、单字符**的连续段合并——
;;;   打字连续段：两条都是「单字符、非换行」纯插入，且 d.起点 = after(pl)
;;;   退格连续段：两条都是「单字符、非换行」纯删除，且 d.末尾 = pl.起点
;;;   前向删除段：同上，且 d.起点 = pl.起点
;;;   其余（换行、粘贴、跨行删除、替换、任何带属性的变更…）一律不合并
;;; 合并时保留**较早**的 位置（撤销回到整段之前）。

(provide
 步骤? 步骤-重放 步骤-撤销 步骤-前-位置
 (struct-out 历史)
 历史-空
 历史-记录
 历史-弹出-撤销
 历史-弹出-重做
 历史-可撤销?
 历史-可重做?
 历史-撤销-深度
 历史-重做-深度)

;;; ---------- 数据 ----------

;; 重放-反向 : (listof 变更)  **逆序**（最新在前）—— 合并时只需 cons，O(1)。
;;   用 步骤-重放 取回正序（公开契约不变）。合并一段长打字原本是每次
;;   (append big (list x))，O(n²)；逆序存储后整段 O(n)。
;; 撤销       : (listof 变更)  正序依次施加（新编辑的逆在前）
(struct 步骤 (重放-反向 撤销 前-位置) #:transparent)

;; 公开访问器：正序 重放（依次施加）。
(define (步骤-重放 s) (reverse (步骤-重放-反向 s)))

(struct 历史 (撤销 重做) #:transparent)
;; 撤销 / 重做 : (listof 步骤)  栈顶在前

(define (历史-空) (历史 '() '()))
(define (历史-可撤销? h) (pair? (历史-撤销 h)))
(define (历史-可重做? h) (pair? (历史-重做 h)))
(define (历史-撤销-深度 h) (length (历史-撤销 h)))
(define (历史-重做-深度 h) (length (历史-重做 h)))

;;; ---------- 合并规则 ----------

(define (字符-插入? d)
  (define t (编辑-描述-新-文本 d))
  (and (位置=? (编辑-描述-起点 d) (编辑-描述-末尾 d))
       (= 1 (string-length t))
       (not (memv (string-ref t 0) '(#\newline #\return)))))

(define (字符-删除? d)
  (and (= (位置-行 (编辑-描述-起点 d)) (位置-行 (编辑-描述-末尾 d)))
       (= (位置-列 (编辑-描述-末尾 d)) (add1 (位置-列 (编辑-描述-起点 d))))
       (string=? (编辑-描述-新-文本 d) "")))

;; 只有「纯文本单条」才可能参与合并。
(define (单个-文本 字符)
  (and (null? (变更-属性集 字符))
       (= 1 (length (变更-文本集 字符)))
       (car (变更-文本集 字符))))

;; 本次 重放 是单条纯文本 变更；返回其 描述。
(define (单个-变更-文本 重放)
  (and (= 1 (length 重放)) (单个-文本 (car 重放))))

(define (重放可合并? 上一个 重放)
  ;; 上一个 的逆序 重放 的头部 = 正序的最后一条。
  (define 上一个-反向 (步骤-重放-反向 上一个))
  (define pch (and (pair? 上一个-反向) (car 上一个-反向)))
  (define pl (and pch (null? (变更-属性集 pch))
                  (pair? (变更-文本集 pch))
                  (last (变更-文本集 pch))))
  (define d (单个-变更-文本 重放))
  (and pl d
       (cond
         [(and (字符-插入? pl) (字符-插入? d))
          (位置=? (编辑-描述-起点 d) (编辑描述-之后的-位置 pl))]
         [(and (字符-删除? pl) (字符-删除? d))
          (or (位置=? (编辑-描述-末尾 d) (编辑-描述-起点 pl))     ; 退格：向左推进
              (位置=? (编辑-描述-起点 d) (编辑-描述-起点 pl)))] ; 前向删除：同点继续
         [else #f])))

;;; ---------- 记录 / 取出 ----------

;; 记一步：重放 / 撤销 都是 变更 的序列（正序施加）。任何记录都清空 重做 栈。
(define (历史-记录 h 重放 撤销 前-位置)
  (define 顶部 (and (pair? (历史-撤销 h)) (car (历史-撤销 h))))
  (cond
    [(and 顶部 (重放可合并? 顶部 重放))
     ;; 合并：新 重放 接在旧 重放 之后（正序）→ 逆序存储即 (reverse 重放) 接在头部。
     ;; 合并分支保证 重放 只有一条，故这是 O(1)（旧实现 (append big …) 是 O(n) → O(n²)）。
     (struct-copy 历史 h
       [撤销 (cons (步骤 (append (reverse 重放) (步骤-重放-反向 顶部))
                         ;; 新的逆在前，旧的在后（撤销顺序）
                         (append 撤销 (步骤-撤销 顶部))
                         (步骤-前-位置 顶部))
                   (cdr (历史-撤销 h)))]
       [重做 '()])]
    [else
     (struct-copy 历史 h
       [撤销 (cons (步骤 (reverse 重放) 撤销 前-位置) (历史-撤销 h))]
       [重做 '()])]))

;; 取出下一步。空栈 → (values #f h)（原样，不报错）。
(define (历史-弹出-撤销 h)
  (cond
    [(null? (历史-撤销 h)) (values #f h)]
    [else
     (define st (car (历史-撤销 h)))
     (values st (struct-copy 历史 h
                  [撤销 (cdr (历史-撤销 h))]
                  [重做 (cons st (历史-重做 h))]))]))

(define (历史-弹出-重做 h)
  (cond
    [(null? (历史-重做 h)) (values #f h)]
    [else
     (define st (car (历史-重做 h)))
     (values st (struct-copy 历史 h
                  [重做 (cdr (历史-重做 h))]
                  [撤销 (cons st (历史-撤销 h))]))]))

;;; ---------- 测试（纯数据 + doc 帮助构造逆） ----------

(module+ test
  (require "../doc/buffer.rkt" "../doc/document.rkt")

  ;; 施加一条文本 描述，并给出 (重放 撤销 前-位置)
  (define (取步骤 b d p)
    (define-values (b* res) (文档-施加-变更 b (编辑列表->变更 (list d)) #:受信? #t))
    (values b* (list (变更-结果-重放 res)) (变更-结果-撤销 res)))
  ;; 模拟一次编辑并记账
  (define (rec h b d p)
    (define-values (b* 重放 撤销) (取步骤 b d p))
    (values (历史-记录 h 重放 撤销 p) b*))
  (define (施加-撤销 b 撤销) (for/fold ([x b]) ([c (in-list 撤销)]) (let-values ([(x* _) (文档-施加-变更 x c #:受信? #t)]) x*)))
  (define (施加-重放 b 重放) (for/fold ([x b]) ([c (in-list 重放)]) (let-values ([(x* _) (文档-施加-变更 x c #:受信? #t)]) x*)))

  ;; 打字连续段并成 1 步
  (define-values (t1 b1) (rec (历史-空) (文档-打开 "") (编辑-描述 (位置 0 0) (位置 0 0) "a") (位置 0 0)))
  (define-values (t2 b2) (rec t1 b1 (编辑-描述 (位置 0 1) (位置 0 1) "b") (位置 0 1)))
  (define-values (t3 b3) (rec t2 b2 (编辑-描述 (位置 0 2) (位置 0 2) "c") (位置 0 2)))
  (check-equal? (文档->字符串 b3) "abc")
  (check-equal? (历史-撤销-深度 t3) 1)
  (define-values (s1 t4) (历史-弹出-撤销 t3))
  (check-equal? (文档->字符串 (施加-撤销 b3 (步骤-撤销 s1))) "")
  (check-equal? (步骤-前-位置 s1) (位置 0 0))
  (check-equal? (历史-重做-深度 t4) 1)
  (define-values (s2 _u1) (历史-弹出-重做 t4))
  (check-equal? (文档->字符串 (施加-重放 (文档-打开 "") (步骤-重放 s2))) "abc")

  ;; 换行打断连续段
  (define-values (n1 nb1) (rec (历史-空) (文档-打开 "") (编辑-描述 (位置 0 0) (位置 0 0) "a") (位置 0 0)))
  (define-values (n2 nb2) (rec n1 nb1 (编辑-描述 (位置 0 1) (位置 0 1) "\n") (位置 0 1)))
  (define-values (n3 _u2) (rec n2 nb2 (编辑-描述 (位置 1 0) (位置 1 0) "b") (位置 1 0)))
  (check-equal? (历史-撤销-深度 n3) 3)

  ;; 退格连续段
  (define-values (k1 kb1) (rec (历史-空) (文档-打开 "abc") (编辑-描述 (位置 0 2) (位置 0 3) "") (位置 0 3)))
  (define-values (k2 kb2) (rec k1 kb1 (编辑-描述 (位置 0 1) (位置 0 2) "") (位置 0 2)))
  (check-equal? (文档->字符串 kb2) "a")
  (check-equal? (历史-撤销-深度 k2) 1)
  (define-values (ks1 _u3) (历史-弹出-撤销 k2))
  (check-equal? (文档->字符串 (施加-撤销 kb2 (步骤-撤销 ks1))) "abc")

  ;; 前向删除连续段
  (define-values (f1 fb1) (rec (历史-空) (文档-打开 "abcde") (编辑-描述 (位置 0 2) (位置 0 3) "") (位置 0 2)))
  (define-values (f2 fb2) (rec f1 fb1 (编辑-描述 (位置 0 2) (位置 0 3) "") (位置 0 2)))
  (check-equal? (文档->字符串 fb2) "abe")
  (check-equal? (历史-撤销-深度 f2) 1)

  ;; 粘贴（多字符）不并
  (define-values (p1 pb1) (rec (历史-空) (文档-打开 "") (编辑-描述 (位置 0 0) (位置 0 0) "a") (位置 0 0)))
  (define-values (p2 _u4) (rec p1 pb1 (编辑-描述 (位置 0 1) (位置 0 1) "XY") (位置 0 1)))
  (check-equal? (历史-撤销-深度 p2) 2)

  ;; 记录新编辑 → 重做 清空
  (define-values (_c1 c2) (历史-弹出-撤销 t3))
  (check-equal? (历史-重做-深度 c2) 1)
  (define-values (c3 _u5) (rec c2 (文档-打开 "") (编辑-描述 (位置 0 0) (位置 0 0) "z") (位置 0 0)))
  (check-equal? (历史-重做-深度 c3) 0)

  ;; 文本 + 属性一步：可撤销
  (define ab0 (文档-打开 "abcd"))
  (define-values (ab1 res)
    (文档-施加-变更 ab0
      (变更 (list (编辑-描述 (位置 0 1) (位置 0 1) "X"))
              (list (属性-设置 (位置 0 1) (位置 0 2) 只读键 #t)))
      #:受信? #t))
  (define ah (历史-记录 (历史-空) (list (变更-结果-重放 res)) (变更-结果-撤销 res) (位置 0 1)))
  (check-equal? (文档->字符串 ab1) "aXbcd")
  (check-equal? (历史-撤销-深度 ah) 1)
  (define-values (as _bpu) (历史-弹出-撤销 ah))
  (check-equal? (文档->字符串 (施加-撤销 ab1 (步骤-撤销 as))) "abcd")
  (check-false (属性-只读? (文档-属性集-在 (施加-撤销 ab1 (步骤-撤销 as)) (位置 0 1))))

  ;; 空栈
  (define eh (历史-空))
  (check-false (let-values ([(s _) (历史-弹出-撤销 eh)]) s))
  (check-false (let-values ([(s _) (历史-弹出-重做 eh)]) s))
  (check-false (历史-可撤销? eh))

  (displayln "history.rkt: all tests passed"))
