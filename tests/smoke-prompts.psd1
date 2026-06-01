@{
    Simulator = @(
        @{
            Name = 'math'
            Model = 'auto'
            Prompt = 'What is the derivative of f(x)=x^3?'
        },
        @{
            Name = 'science'
            Model = 'auto'
            Prompt = 'Explain photosynthesis in two sentences.'
        },
        @{
            Name = 'general'
            Model = 'auto'
            Prompt = 'Say hello in one sentence.'
        }
    )

    Airunway = @(
        @{
            Name = 'basic-completion'
            Prompt = 'Write one short sentence introducing yourself.'
        }
    )
}
