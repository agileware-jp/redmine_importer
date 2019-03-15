module SafeVisit
  def safe_visit(path)
    visit path
    expect_page_to_render_without_exception
  end

  def safe_click_link(link)
    click_link link
    expect_page_to_render_without_exception
  end

  def safe_click_button(link)
    click_button link
    expect_page_to_render_without_exception
  end

  def expect_page_to_render_without_exception
    expect(page.title).not_to include('Exception caught'), "Exception caught while visiting #{page.current_path}: #{page.text}"
  end
end

RSpec.configure do |config|
  config.include SafeVisit, type: :feature
end
