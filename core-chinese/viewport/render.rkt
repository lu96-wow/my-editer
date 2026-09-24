#lang racket

(require "../atom/point.rkt" "../doc/buffer.rkt" rackunit)

;;; viewport/render.rkt —— 单行渲染：缓冲 一行 → 字形 向量
;;;
;;; 外观 **全部来自投影参数 外观-提供者**（派生 外观 = 内容 的纯函数，如语法高亮）；
;;; 文档里不存 外观。提供者 : 缓冲 行 -> (listof (list 起点 末尾 外观))。
;;; 布局（折行/裁剪）、屏幕帧、滚动都在 视口 层，与本层无关。

(provide
 (struct-out 字形)
 (struct-out 已渲染-行)
 空外观提供者
 渲染-行)

(struct 字形 (字符 外观) #:transparent)
;; 外观 : any/c（语义值；结构由应用定义，常用 (hash '外观 '关键字)）

(struct 已渲染-行 (字形集) #:transparent)
;; 字形集 : (vectorof 字形)

;; 缺省 提供者：无派生 外观。
(define (空外观提供者 _b _line) '())

;; 片段集 按 起点 升序的 (起点 末尾 payload)。返回覆盖列 a 的 payload（#f 未覆盖），
;; 以及其后第一个 末尾 > a 的剩余 片段集。让每段只需向前走，整体 O(D)。
(define (片段-覆盖-在 片段集 a)
  (let 跳过 ([r 片段集])
    (cond
      [(null? r) (values #f r)]
      [(<= (cadr (car r)) a) (跳过 (cdr r))]
      [(<= (car (car r)) a) (values (caddr (car r)) r)]
      [else (values #f r)])))

(define (渲染-行 b i [外观-提供者 空外观提供者])
  (define 文本 (缓冲-行-引用 b i))
  (define n (string-length 文本))
  (define d-片段集 (外观-提供者 b i))
  (define 位置列表
    (sort (remove-duplicates
           (append (list 0 n)
                   (append-map (lambda (段) (list (car 段) (cadr 段))) d-片段集)))
          <))
  (define 字形集 (make-vector n #f))
  (let loop ([pts (drop-right 位置列表 1)] [bnd (rest 位置列表)] [di d-片段集])
    (cond
      [(null? pts) (void)]
      [else
       (define a (car pts)) (define z (car bnd))
       (define-values (dface di*) (片段-覆盖-在 di a))
       (define 外观 dface)                       ; 无 外观 段 → #f（core 不发明任何 外观 值）
       (for ([j (in-range a z)]) (vector-set! 字形集 j (字形 (string-ref 文本 j) 外观)))
       (loop (cdr pts) (cdr bnd) di*)]))
  (已渲染-行 字形集))

;;; ---------- 测试 ----------

(module+ test
  (define (外观-在 b i j [提供者 空外观提供者])
    (字形-外观 (vector-ref (已渲染-行-字形集 (渲染-行 b i 提供者)) j)))

  (define b0 (缓冲-打开 "hello\nworld"))
  ;; 无 提供者 → 无 外观；提供者 在投影时给出派生 外观
  (check-equal? (外观-在 b0 0 0) #f)                        ; 无 提供者 → #f

  ;; 派生 外观：投影时给出，不进文档
  (define (提供者 _b 行)
    (if (zero? 行) (list (list 0 5 (hash '外观 '关键字))) '()))
  (check-equal? (外观-在 b0 0 0 提供者) (hash '外观 '关键字))
  (check-equal? (外观-在 b0 1 0 提供者) #f)               ; 第 1 行无匹配

  ;; 多段
  (define (provider2 _b _line)
    (list (list 0 2 (hash '外观 'a)) (list 3 5 (hash '外观 'b))))
  (check-equal? (外观-在 b0 0 0 provider2) (hash '外观 'a))
  (check-equal? (外观-在 b0 0 2 provider2) #f)
  (check-equal? (外观-在 b0 0 3 provider2) (hash '外观 'b))

  (displayln "render.rkt: all tests passed"))
